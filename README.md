# SpektraLab for iOS

SpektraLab 的 iPhone 社区移植版。它使用 C++20 与 Metal 运行真实的胶片/相纸物理模拟：照片会经过胶片曝光、染料层、颗粒、光晕、放大和相纸成像流程，而不是简单套用一张 LUT。

> 本项目不是 SpektraLab 官方 iOS 客户端。核心引擎来自 [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab)，本仓库维护 iOS 界面、RAW/JPEG 导入、Metal 适配、照片导出和自动构建。

## 当前版本

| 项目 | 状态 |
|---|---|
| 最低系统 | iOS 27.0 |
| 开发环境 | Xcode 27.2、Swift 6、C++20、Metal |
| 界面 | 原生 Liquid Glass，底部横向胶片/相纸选择条 |
| 导入 | JPEG、Apple RAW/DNG，以及系统支持的 Sony ARW |
| 导出 | 原始像素分辨率的 8-bit sRGB JPEG（当前解码上限 6400 万像素） |
| 预览 | 保持原始宽高比，支持缩放、拖动和双击复位 |
| 配置 | 26 款胶片/正片配置、7 款相纸配置 |

目前仍处于测试阶段。不同 iPhone 和 iOS 版本支持的相机 RAW 型号可能不同，重要照片请保留原文件。

## 下载

前往 **[Latest Release](https://github.com/Minerchu/SpektraLab-iOS/releases/latest)** 下载最新 IPA。文件名包含提交号，用于避免 GitHub CDN 返回旧版本。

Release 中有两个文件：

| 文件 | 用途 |
|---|---|
| `SpektraLab-<提交号>-unsigned.ipa` | SideStore、AltStore 等会自行重签的工具，推荐这类工具使用 |
| `SpektraLab-<提交号>.ipa` | ad-hoc 封签版，供 Sideloadly、Xcode 或其他签名流程使用 |

GitHub Release 中的 IPA 不带你的个人开发证书，不能直接双击安装，必须先用自己的 Apple ID 或开发证书重签。

## 安装

### SideStore / AltStore

1. 下载 `SpektraLab-<提交号>-unsigned.ipa`。
2. 在 SideStore 或 AltStore 中选择该文件。
3. 使用自己的 Apple ID 完成重签和安装。
4. 免费 Apple ID 的签名通常 7 天后过期，需要重新签名。

### Sideloadly

1. 下载普通的 `SpektraLab-<提交号>.ipa`。
2. 连接 iPhone，在 Sideloadly 中选择 IPA。
3. 使用自己的 Apple ID 签名并安装。

### Xcode

克隆仓库，在 Xcode 中登录 Apple ID，把 Signing 设置为自己的 Personal Team，然后连接 iPhone 运行。设备必须满足 iOS 27.0 最低版本。

## 使用方法

1. 引擎资源随安装包内置，首次启动自动在本地解包，无需联网下载。
2. 点击顶部照片按钮，从系统相册导入 JPEG、Apple RAW 或 DNG。
3. Sony ARW 建议使用“从文件导入 Sony ARW / RAW”，这样应用可以读取原始文件，而不是相册生成的预览图。
4. 在底部横向滑动并选择胶片，再切换到“相纸”选择相纸。
5. 在“调整”中修改曝光、颗粒、光晕等参数。
6. 双指放大预览，放大后拖动查看细节；双击照片恢复适合屏幕。
7. 点击右上角导出按钮，应用会重新渲染并以 JPEG 保存到系统相册。

## 图片与颜色管线

### 导入

- JPEG 通过 ImageIO 解码。
- Apple RAW/DNG 和 Sony ARW 优先通过 Core Image 的 RAW 解码器读取。
- RAW 解码会关闭 Core Image 默认的额外曝光、全局曲线、局部 tone map、EDR 和 gamut mapping，避免同一张照片在 iOS 上被重复提亮。
- 解码结果转换为引擎需要的线性 ProPhoto RGB。
- 预览长边限制为 2048 px，以降低手机内存和实时切换胶片时的负担。

Sony ARW 是否可解码由 iOS/Core Image 对具体相机型号的支持决定。无法识别时应用会显示导入错误，不会把错误数据继续交给胶片引擎。

### 预览与导出

- 引擎输出固定为 sRGB，与桌面预览主机保持一致。
- 画布按照片真实比例显示，不再把竖图或横图压进固定 2:3 框架。
- 导出会重新读取原始文件并完整运行胶片流程。
- 预览使用长边 2048 px；导出重新读取原图，使用原始像素分辨率并启用引擎分条处理。大图真机内存表现仍需验证。
- Metal 纹理按行分块读取，JPEG 直接写入临时文件，避免同时生成多个全尺寸内存副本。
- 无论导入 JPEG 还是 RAW，最终都保存为带 sRGB 描述的 JPEG。

## 界面

- iOS 27 上使用系统原生 Liquid Glass。
- 胶片和相纸采用底部横向选择条，切换时照片始终可见。
- 配置文件只包含实测参数和名称，不包含官方胶片封面，因此当前使用统一胶卷徽标和颜色区分各配置。
- 顶部区域保持紧凑，为照片预览保留更多空间。

## 本地构建

### 要求

- macOS
- Xcode 27.2 或更新版本
- iOS 27 SDK
- Apple silicon Mac
- 如需安装到真机，需要在 Xcode 登录 Apple ID

### 构建步骤

```bash
git clone https://github.com/Minerchu/SpektraLab-iOS.git
cd SpektraLab-iOS

# 获取仓库固定版本的上游引擎
git clone https://github.com/JamesQiu2005/SpektraLab.git engine
cd engine
git checkout 02d82b56cf65f0f8e802a708612edc4e9a4790af
cd ..

# 应用 iOS 补丁并生成真机 Metal 资源
python3 tools/apply-ios-patch.py engine
ios/Tools/build-engine.sh bundle device

# 生成 Xcode 工程
python3 ios/Tools/gen-project.py

# 打开工程
open ios/SpektraLab.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中选择自己的 Team，然后选择已连接的 iPhone 运行。

命令行无签名编译：

```bash
xcodebuild \
  -project ios/SpektraLab.xcodeproj \
  -scheme SpektraLab \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

模拟器必须使用单独编译的 Metal 资源：

```bash
ios/Tools/build-engine.sh bundle simulator
```

真机和模拟器的 `.metallib` 不能混用。构建脚本会为 Xcode 27 的模拟器显式使用 `air64-apple-ios27.0-simulator` target。

## GitHub Actions

每次向 `main` 推送代码时，工作流会：

1. 获取固定提交的上游引擎。
2. 应用 iOS 补丁。
3. 编译 Metal 内核并发布首次启动所需的引擎资源。
4. 生成 Xcode 工程和 App 图标。
5. 构建并打包 IPA。
6. 更新滚动的 `latest` Release。

未配置签名 secret 时，CI 仍会发布可供 SideStore、AltStore、Sideloadly 或 Xcode 重签的 IPA。若要生成带开发证书的 IPA，需要在仓库的 Actions secrets 中配置：

- `IOS_CERTIFICATE_P12`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_CERTIFICATE_IDENTITY`
- `IOS_PROVISIONING_PROFILE`
- `IOS_PROVISIONING_PROFILE_NAME`
- `IOS_TEAM_ID`
- `IOS_BUNDLE_ID`

不要把证书、密码、GitHub Token 或 Apple ID 凭据提交到仓库。

## 目录结构

| 路径 | 内容 |
|---|---|
| `ios/SpektraLab/` | SwiftUI 界面、图片导入、Metal 画布、状态与导出逻辑 |
| `ios/Tools/` | Metal 资源、Xcode 工程与 IPA 构建脚本 |
| `tools/` | 上游引擎下载、iOS 补丁和图标工具 |
| `.github/workflows/` | GitHub Actions 自动构建与 Release 发布 |
| `docs/` | iOS 移植技术说明 |

## 已知限制

- Sony ARW 支持取决于 iOS/Core Image 是否支持对应相机型号。
- Apple ProRAW 建议从“文件”导入原始 DNG；从照片库选择时，系统有时只提供渲染后的图像。
- 当前解码上限为 6400 万像素；原始分辨率导出会比低清预览耗时、占用更多内存。
- 清理缓存后从安装包重新解包资源，无需下载。
- 曲线编辑器、色轮、批量处理、片边、日期后背、半格拼接和几何裁剪尚未在 iPhone UI 中开放。
- 免费 Apple ID 侧载签名通常需要每 7 天续签。

## 许可与致谢

- 核心引擎与胶片过程模型：[JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab)，GPL-3.0-or-later。
- 胶片模型、实测配置与放大 LUT：[Andrea Volpato/spektrafilm](https://github.com/andreavolpato/spektrafilm)，CC BY-SA 4.0。
- iOS 移植代码：GPL-3.0-or-later。

代码按 **GPL-3.0-or-later** 分发；胶片与相纸配置按 **CC BY-SA 4.0** 分发。第三方项目的商标和名称归各自权利人所有。
