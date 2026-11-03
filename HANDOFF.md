# 交接说明 — SpektraLab-iOS IPA 构建

> 给接手继续修的 agent。本文记录**当前精确状态**、**已踩过的坑**、**剩余问题**和**建议方案**。
> 最后更新：2026-11-03

## 一句话现状

**编译 100% 通过，且 CI 已不再依赖 `xcodebuild archive`。**

根因（已确认并绕开）：archive 在写 `.xcarchive/Info.plist` 时是**从代码签名里**读取
bundle id / Team 的。CI runner 上没有证书与描述文件，归档出来的 .app
`code object is not signed at all`，这个读取为空，xcodebuild 就报出误导性的
`Archive Missing Bundle Identifier`。这解释了为什么改 Info.plist（值本来就对）、
改 `CODE_SIGN_STYLE`、去 `VALIDATE_PRODUCT`、加 `CODE_SIGNING_ALLOWED=NO` **全都无效**
—— 病根从来不在这些地方。

**现在的 CI 结构**（`.github/workflows/build-ios.yml`，共 15 步）：

- `Build`：签名 secret 齐全 → 走 `archive`；否则 → 直接
  `xcodebuild ... build CODE_SIGNING_ALLOWED=NO`，产出
  `Release-iphoneos/SpektraLab.app`，并把 `BUILD_MODE=archive|package` 写进
  `$GITHUB_ENV`。
- `Package the IPA`：archive 模式走 `-exportArchive`（正规签名 IPA）；package
  模式把 .app 拷进 `Payload/`，自己 `codesign --force --sign -` ad-hoc 签名，再用
  `ditto -c -k --keepParent` 打成 `build/ipa/SpektraLab-unsigned.ipa`（用 `ditto`
  不用 `zip`：iOS 需要它保留的 bundle 元数据与符号链接）。

所以**无 secret 也能出 IPA 工件**，但它是 ad-hoc 签名、装不上真机 ——
要么用 AltStore/Xcode 以自己的 Apple ID 重签，要么配齐下面那 7 个 secret 走正规签名路径。

## 以下保留原始踩坑记录（仍是有效背景，勿重复尝试）


**编译已经 100% 通过**（Swift + 引擎 C++ + metallib 内核 + 资源烘焙 + App icon + 工程生成），
CI 目前卡在 `Build` 步骤的 **archive 收尾阶段**：

```
xcodebuild: error: Archive Missing Bundle Identifier
```

不是代码编译错误，是 **CI 无签名证书 + Xcode 16 archive 元数据组装** 的问题。

## 仓库与 CI

| 项 | 值 |
|---|---|
| 仓库 | `Minerchu/SpektraLab-iOS`，分支 `main` |
| Workflow | `.github/workflows/build-ios.yml` |
| 引擎来源 | 上游 `JamesQiu2005/SpektraLab`，固定 commit `02d82b56cf65f0f8e802a708612edc4e9a4790af` |
| 引擎拉取 | `tools/fetch-engine.py`（**必须用 `${{ github.token }}`**，匿名 API 只有 60 次/小时会 403） |
| 引擎 iOS 补丁 | `tools/apply-ios-patch.py`（拉取后由 CI 应用） |
| 工程生成 | `ios/Tools/gen-project.py`（CI 每次构建重新生成 pbxproj 与 xcscheme） |
| 最低系统 | `IOS_MIN = "16.0"`（gen-project.py 里，**不要误用 iOS 17 API**） |
| Swift | 6.0 + `SWIFT_STRICT_CONCURRENCY = complete` |

CI 步骤顺序：checkout → fetch engine → check profiles → patch engine → Metal toolchain
→ kernels & resources → App icon → generate project → install cert(跳过) → install
profile(跳过) → say what is missing → **Build(失败)** → export IPA(跳过) → upload。

签名相关 secret 全部未配置，所以 `Install the signing certificate` / `Install the
provisioning profile` 两步被跳过，`ExportOptions.plist` 走 ad-hoc 分支。

## 当前卡点的精确诊断

最后一次 CI（run `41595779767`，commit `a62a30eeb2`）Build 步骤失败，日志尾部：

```
xcodebuild: error: Archive Missing Bundle Identifier
=== diagnostic: CFBundleIdentifier in the built app ===
build/SpektraLab.xcarchive/Products/Applications/SpektraLab.app/Info.plist
com.hanze.spektralab            <-- .app 里是对的
=== source Info.plist ===
com.hanze.spektralab            <-- 源码 plist 也是对的
=== .xcarchive/Info.plist ===
FileNotFoundError: .../build/SpektraLab.xcarchive/Info.plist   <-- 没生成
=== codesign state of the archived app ===
code object is not signed at all  <-- app 完全没签名
```

关键点：

- `.app/Info.plist` 的 `CFBundleIdentifier` **确实存在且正确**，所以**不要再往 plist 里找问题**。
- `Info.plist` 里的值已由 `gen-project.py` 写成字面量 `com.hanze.spektralab`
  （`write_infoplist_bundle_id()`），不再依赖 `$(PRODUCT_BUNDLE_IDENTIFIER)` 变量展开。
- `PRODUCT_BUNDLE_IDENTIFIER = com.hanze.spektralab` 在 build settings 里也已解析出来。
- 日志里**没有 CodeSign 步骤**，`.xcarchive/Info.plist` 没生成 —— Xcode 16 在组装
  archive 元数据时读不到「已签名产品」的 bundle id，于是报这个误导性错误。
- 最近一轮我在 archive 命令上加了 `CODE_SIGNING_ALLOWED=NO`，它让 app 变成
  「code object is not signed at all」，**很可能正是它导致/加剧了这个问题**，
  接手时优先考虑撤掉或改成 ad-hoc 签名。

## 已经修完的问题（按修复顺序，勿重复踩坑）

1. **引擎拉取**：匿名 GitHub API 限流 403 → 改用 `tools/fetch-engine.py` + `${{ github.token }}`
   （认证 5000 次/小时），用 Contents API 批量取文件而非 git clone。上游仓库无 Git LFS。
2. **App icon 步骤 PEP 668**（Homebrew Python 拒绝 pip install）→ 改用 venv。
3. **`-archivePath` / `-derivedDataPath` 必须配 `-scheme`** → 在 `gen-project.py` 里生成
   shared scheme（写入 `xcshareddata/xcschemes/SpektraLab.xcscheme`）。
4. **`HEADER_SEARCH_PATHS` 层级算错**：`$(SRCROOT)` 是 `ios/`，引擎在仓库根，
   所以是 `$(SRCROOT)/../engine/...`（一级），不是 `../../`（两级）。
5. **9 个 Swift 编译错误**，全部修完：
   - `makeDefaultLibrary(bundle: .main)` 返回值处理
   - `Stock.Type` → `Stock.FilmType`（`Type` 与 Swift 元类型冲突）
   - `ViewModel.State` → `AppState`（与 SwiftUI 的 `State` 冲突，曾导致 `.failed`
     被解析成手势 phase 的诡异报错）
   - `buffer.contents()!` 强解包 → 安全解包
   - `Transferable` 的 `DataRepresentation(importedAs:)` 标签
   - `MTLTexture` 不是 `Hashable`、没有 `hashValue` → 改用 `renderIdentity`（引擎 progressID）
   - `previous == .failed` → `if case .failed = previous`（带关联值的 case 不能用 `==`）
   - `Task` 初始化器歧义 → 统一写 `Task<Void, Never>(priority:)` / `Task<Void, Never>`
   - `toolbar(content:)` 歧义 → 整个移除 `.toolbar`，改成 body 里普通 `HStack` 顶栏
     （`ContentView.swift` 的 `topBar`）；`StockPicker` 里那个单个 `ToolbarItem` 的
     `.toolbar` 不冲突，保留。
6. **根因级大坑：`.onChange(of:initial:_:)` 是 iOS 17 API，而 target 是 16.0**。
   之前一连串「Task 歧义 / toolbar 歧义」全是它引发的连锁误报。最终解法：
   **完全不用 onChange**，把导入触发放进 `PhotosPicker` 的自定义
   `Binding<PhotosPickerItem?>` setter 里；两处 Task 都加 `@MainActor in`
   （ViewModel 是 `@MainActor`，Task 闭包是 `@Sendable`，Swift 6 严格并发要求）。
7. **ViewModel init**：`let renderer` 无默认值 + init 里有早退 → `return without
   initializing all stored properties`。改成 `private(set) var renderer: CanvasRenderer? = nil`。
8. **引擎补丁两处 C++ 错误**（`tools/apply-ios-patch.py`）：
   - `fire_test_pressure_if_asked()` 定义被 `#if TARGET_OS_OSX` 包了，但上游有 **2 处
     调用**（第 234、258 行）没包 → 给定义补 `#else` 空实现，调用点不用动。
   - `MTL::TextureUsageCopySource` **在 metal-cpp 里根本不存在**（blit 复制不需要
     usage 声明）→ 直接删掉那条 change，保持上游 `setUsage(MTL::TextureUsageShaderRead)`。
9. **签名风格判断写反**：`CODE_SIGN_STYLE` 改成始终 `Manual`
   （无证书时 `CODE_SIGN_IDENTITY = "-"` 即 ad-hoc；Automatic 需要 Team 和 Apple 账号，
   在无凭据 CI 上必失败）。
10. **`VALIDATE_PRODUCT = YES`** 从 Release 配置移除（它会触发
    `builtin-validationUtility` 校验无签名 app）。

## 给接手 agent 的建议（按优先级）

### 方案 A（推荐，最省事）：绕过 archive，直接从 build 产物打 IPA

编译已经全过了，没必要跟 Xcode 的 archive 签名逻辑纠缠。把 Build 步骤的
`archive` 换成普通 `build`，然后从 `DerivedData` 里把 `.app` 打包：

```bash
xcodebuild -project ios/SpektraLab.xcodeproj \
  -scheme SpektraLab -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee build/xcodebuild.log

APP=$(find build/DerivedData/Build/Products -maxdepth 2 -type d -name 'SpektraLab.app' | head -1)
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry SpektraLab.ipa Payload)
```

这样 **无需任何签名证书**就能产出可下载的 IPA（未签名，装不了真机，但足以验证
整条编译链路并交付产物）。相应地，`Export the IPA` 步骤需要改成：若
`build/ipa/*.ipa` 已存在就跳过 `-exportArchive`。

### 方案 B：让 archive 成功

- 撤掉 `CODE_SIGNING_ALLOWED=NO`，改用显式 ad-hoc 签名：
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual`
- 或在 archive 前用 `codesign -s -` 给产物做 ad-hoc 签名。
- 若仍报 `Archive Missing Bundle Identifier`，可考虑 `-skipUnavailableDevices`、
  检查 scheme 的 `ArchiveAction`、或干脆保留方案 A 的兜底。

### 方案 C：配齐 7 个 secret，走正规签名

`tools/set-github-secrets.py` 可从本地文件一次性写入。所需 secret：

```
IOS_CERTIFICATE_P12            # 证书 p12 的 base64
IOS_CERTIFICATE_PASSWORD
IOS_CERTIFICATE_IDENTITY       # e.g. "Apple Development: NAME (TEAMID)"
IOS_PROVISIONING_PROFILE       # 描述文件 base64
IOS_PROVISIONING_PROFILE_NAME
IOS_TEAM_ID
IOS_BUNDLE_ID
```

有证书后 `Export the IPA` 会走 development 分支，产出可装真机的 IPA。

### 强烈建议：保留兜底

无论选 A/B/C，让 Build 步骤在 archive 失败时**自动回退到方案 A 直接打 IPA**，
这样 CI 永远有产物可下载，不会出现「编译全过但 artifact 为空」。

## 本地环境与工具（重要）

- 工作副本：`C:\Users\sodaer\WorkBuddy\2026-11-03-10-51-37\work\SpektraLab-iOS\`
- 本机是 Windows，**没有 Xcode**，只能在 GitHub Actions 的 macOS runner 上编译。
- 本机 PortableGit 缺 `git-remote-https`，`git clone/push` 走 HTTPS 会失败；
  用 GitHub **Contents API / Git Data API** 推送：
  - 全量单 commit：`tools/push-to-github.py`（脚本内 `files()` 决定推哪些文件，
    排除 `engine/`、`build/`、`.git/` 等）
  - 单文件快速推：`work/push_files.py <repo> <path...>`（从 `GITHUB_TOKEN` 读 token）
  - 带重试全量推：`work/push_retry.py`
- CI 结果监控：`work/watch_ci.py <run_id>`（等待完成并抽取编译错误）。
  ⚠️ 该脚本里**硬编码了 GitHub token**，**绝对不要提交进仓库**；如需复用请先改成读环境变量。
- `tools/push-to-github.py` 与 `tools/fetch-engine.py` 从环境变量读 token，是干净的。

## 验证当前 CI 状态的办法

```
GET /repos/Minerchu/SpektraLab-iOS/actions/runs?per_page=3
GET /repos/Minerchu/SpektraLab-iOS/actions/runs/{id}/jobs
GET /repos/Minerchu/SpektraLab-iOS/actions/runs/{id}/logs   # zip，解压看 ipa/13_Build.txt
```

`Build` 步骤的失败诊断输出已写进 workflow，会打印 `.app` 与源码 plist 的
`CFBundleIdentifier`、`.xcarchive/Info.plist`、`codesign -dv` 结果、
以及解析出的 `PRODUCT_BUNDLE_IDENTIFIER`，排查时直接看日志尾部即可。
