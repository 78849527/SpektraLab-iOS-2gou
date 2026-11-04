# SpektraLab for iOS

把 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) 的胶片/相纸物理模拟引擎搬到 iPhone。

打开一张 RAW，选好胶片和相纸，几秒内得到一张按物理过程建模的照片——81 个波长穿过染料层，颗粒、光晕、成色剂耦合按画幅的微米尺度计算，不是 LUT。

> 这是社区移植，不是上游官方版本。引擎来自上游 `main` 分支（C++20 + Metal），本仓库只包含 iOS 应用、引擎的 iOS 补丁与构建脚本。

## 为什么 iOS 走 Metal 而不是 Vulkan

安卓版走 Vulkan，因为 Android 没有 Metal。iOS 原生就是 Metal，所以这一版**直接复用上游已有的 Metal 后端**（`engine/src/gpu/metal_gpu.cpp`），不碰 Vulkan。

这不是抄近路，是抄到了更近的路：

- **引擎的 Metal 后端可移植性极好**——纯 C++ + metal-cpp，没有任何 AppKit / UIKit / Cocoa 依赖，着色器是预编译的 `.metallib`（不是运行时编译，合 App Store 审核）。
- **白捡一个能力**：对比度蒙版（`contrast_mask`）在 Vulkan 后端未移植，安卓版只能显式拒绝；Metal 后端是完整的。
- **少一层转换**：Vulkan 在 iOS 上要靠 MoltenVK 转译，多一层损耗和一层不确定性。

`engine/src/gpu/metal_gpu.cpp` 是唯一需要改的引擎文件，改了三处，都记在 `tools/apply-ios-patch.py` 里。

## 引擎的改动

| 改动 | 为什么 |
|---|---|
| 内存压力监控包在 `#if TARGET_OS_OSX` 里 | `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 在 iOS SDK 里不存在，不改就编译不过。共用同一个队列的 idle timer 不受影响，它在 iOS 上照常工作。 |
| 结果纹理 usage flag | 曾尝试加 `MTLTextureUsageCopySource`，但 `metal-cpp` 里没定义这个枚举（metal-cpp 不完备），实际 blit 回读也不需要它 —— 保留上游的 `ShaderRead`。 |
| `GPUFamilyMac2` 包在 `#if TARGET_OS_OSX` 里 | iOS 没有这个 family。 |

补丁脚本每处改动都先断言命中次数，全部命中才写盘，并且检查 `#if`/`#endif` 是否平衡——一个悄悄没打上的补丁，会在很远的地方以「引擎 bug」的样子炸掉。

## 下载

打开 **[latest release](https://github.com/Minerchu/SpektraLab-iOS/releases/latest)**，
下载里面那个 `SpektraLab-<提交号>.ipa`。

文件名带提交号不是装饰。`releases/download/<tag>/<固定名>` 走 CDN，同名替换后
一段时间内仍会返回**旧文件**——你会装上旧包，侧载时看到
`Failed to get bundle ID`（旧包的 `Payload/` 目录结构和 Info.plist 都不对）。
每次文件名都不同，就不会撞上这层缓存。

未配签名 secret 时这个 IPA 需要你自己重签才能装到手机——见下面「装到手机上」一节。

## 目录

| 路径 | 内容 |
|---|---|
| `ios/SpektraLab/` | 应用：SwiftUI 界面、Swift↔C 桥接、Metal 画布、ImageIO 解码 |
| `ios/Tools/` | 构建脚本：引擎内核、生成 Xcode 工程、打包 IPA |
| `tools/` | 引擎补丁、图标生成 |
| `.github/workflows/` | 云端构建 IPA |

## 构建

### 云端（不需要 Mac）

GitHub Actions 会在 macOS runner 上拉引擎、打补丁、编译内核、构建签名、导出 IPA。

需要先在仓库的 **Settings → Secrets and variables → Actions** 里加这几个 secret：

| Secret | 内容 |
|---|---|
| `IOS_CERTIFICATE_P12` | `.p12` 的 base64（macOS 上 `base64 -i cert.p12 \| pbcopy`） |
| `IOS_CERTIFICATE_PASSWORD` | `.p12` 的密码 |
| `IOS_CERTIFICATE_IDENTITY` | 证书名，如 `Apple Development: Zhang San (ABCDE12345)` |
| `IOS_PROVISIONING_PROFILE` | `.mobileprovision` 的 base64 |
| `IOS_PROVISIONING_PROFILE_NAME` | 描述文件在 Xcode 里显示的名字 |
| `IOS_TEAM_ID` | 十位团队 ID |
| `IOS_BUNDLE_ID` | 描述文件对应的 bundle id |

然后点 **Actions → Build IPA → Run workflow**。IPA 会出现在该次运行的 **Artifacts → SpektraLab-IPA** 里。

没配 secret 也能跑，但产物需要自己重签才能装手机——工作流会在日志里明确警告。成功构建后 IPA 会自动发布到 [latest release](https://github.com/Minerchu/SpektraLab-iOS/releases/latest)。

### 本地（有 Mac）

```bash
git clone https://github.com/Minerchu/SpektraLab-iOS.git
cd SpektraLab-iOS

# 1) 上游引擎
git clone https://github.com/JamesQiu2005/SpektraLab.git engine
cd engine && git checkout 02d82b56 && cd ..

# 2) 打 iOS 补丁、编译内核、生成工程、构建签名、导出 IPA
export SPEKTRAFILM_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
export SPEKTRAFILM_TEAM_ID=TEAMID
export SPEKTRAFILM_PROVISIONING_PROFILE="Your Profile"
export SPEKTRAFILM_BUNDLE_ID=com.hanze.spektralab

ios/Tools/build-ipa.sh
```

产物在 `build/ipa/`。

## 装到手机上

IPA 不能直接双击安装。三种办法：

1. **AltStore / SideStore**（免费，推荐）—— 把 IPA 拖进 AltStore，它会用你的 Apple ID 重签。免费账号的签名 **7 天**过期，到期重签即可。
2. **Sideloadly** —— Windows 上直接刷，连接手机后点一下。同样 7 天。
3. **付费开发者账号 + Ad Hoc 描述文件** —— 把手机的 UDID 加进描述文件，签名有效期 **1 年**，不用每周重签。

## 已知限制

- **RAW 解码依赖 Core Image / ImageIO**，不是 LibRaw。选择照片时优先读取原始 RAW 字节；解码时把 Core Image RAW 输出固定到 sRGB 后再进入引擎的线性 ProPhoto 输入空间。支持随 iOS 版本和机型变化的 ARW / Apple RAW / DNG 等格式，解不了的格式会明确报错，不会悄悄渲错。
- **导入按长边 3072 px 缩放**。引擎的 live 档渲染上限是长边 2048 px，预览用不着更大的图；而手机内存扛不住 45 MP 的 float32 解码（48 MB 起）。导出时会以原始分辨率重新解码。
- **导出是 8-bit sRGB JPEG**。无论导入 JPG 还是 RAW，保存到相册前都会明确编码为 JPEG；工作空间是 ProPhoto RGB，导出时转换到 sRGB。
- 片边（Film Edge）、日期后背、半格拼接、几何裁剪**引擎侧已实现但 UI 未接**——和安卓版一样。
- 曲线编辑器、色轮、胶片条、多窗口、Agent/MCP server 这些 macOS 桌面形态的功能**没有移植**，iPhone 上用不上。

## 致谢与许可

- 引擎、胶片过程模型与上游实现：[JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab) — GPL-3.0-or-later
- 胶片模型、28 款实测配置与放大 LUT：[Andrea Volpato 的 spektrafilm](https://github.com/andreavolpato/spektrafilm) — CC BY-SA 4.0
- 本仓库：iOS 移植（Metal 引擎适配、SwiftUI 界面、ImageIO 解码、CI 打包）— GPL-3.0-or-later

代码以 **GPL-3.0-or-later** 分发；胶片与相纸配置以 **CC BY-SA 4.0** 分发。
