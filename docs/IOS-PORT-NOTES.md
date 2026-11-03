# iOS 移植的技术决策

这个文件记的是**为什么**,而不是**是什么**。代码里有是什么。

## 为什么走 Metal 而不是 Vulkan

安卓版走 Vulkan,是因为 Android 没有 Metal。iOS 原生就是 Metal,所以这一版直接复用上游
`engine/src/gpu/metal_gpu.cpp`。

这不是"抄近路",是"抄到了更近的路":

1. **可移植性**:`metal_gpu.cpp` 是纯 C++ + metal-cpp,没有任何 AppKit / UIKit / Cocoa 依赖。
   全引擎(不含 vendored 的 metal-cpp)搜不到 `NSImage`/`NSColor`/`NSView` 之类的引用。
2. **着色器合规**:引擎加载的是**预编译的 `.metallib`**(`device->newLibrary(path)`),
   不是运行时 `newLibraryWithSource`。后者在 iOS 上不允许(App Store 审核问题)。
3. **少一层转换**:Vulkan 在 iOS 上要靠 MoltenVK 转译,多一层损耗和一层不确定性。
4. **白捡一个能力**:`contrast_mask` 在 Vulkan 后端未移植,安卓版只能在
   `capabilities.backend.unsupported_features` 里显式拒绝。Metal 后端是完整的。

## 引擎的输入契约

**引擎期望调用方交给他线性 ProPhoto RGB 的浮点像素。**

这不是猜的,是读出来的:

- `engine/src/core/params.hpp:409` — `input_color_space = "ProPhoto RGB"`(默认)
- `engine/src/core/params.hpp:410` — `input_cctf_decoding = false`(默认)
- `engine/src/pipeline/pipeline.cpp:587` — `node_decode_input` 在
  `input_cctf_decoding == false` 时直接 `out = in`,**引擎不替调用方解码**
- `engine/src/pipeline/pipeline.cpp:576` — `node_input_cast` 只丢 alpha 通道,
  **不做任何色彩空间转换**

所以 iOS 端用 ImageIO 解码后必须自己做:sRGB → 线性 → 线性 ProPhoto。

## 传递函数:ProPhoto 的不是 sRGB 的

这是最容易错、而且错得很安静的地方。

`engine/src/pipeline/pipeline.cpp:41` 的 `cctf_mode_for`:

```cpp
if (cs == "sRGB" || cs == "Display P3") return 0;
if (cs == "ProPhoto RGB") return 1;
```

`engine/src/shaders/nodes.metal:242` 的 `cctf_decode_mode`:

```
mode 0 (sRGB):     (0.040449936 >= v) ? v/12.92 : pow((v+0.055)/1.055, 2.4)
mode 1 (ProPhoto): (v < 16/512)      ? v/16    : pow(v, 1.8)
```

**ProPhoto 是 gamma 1.8 + 16 倍线性脚,不是 sRGB 的 gamma 2.4 + 12.92 斜率。**

后果:

- **输入端**:ImageIO 给的是 sRGB 编码,所以解码要用 **sRGB 曲线**(mode 0)——这一步对了。
- **输出端**:引擎的纹理是 **gamma 编码的 ProPhoto**(`io.output_cctf_encoding = true`,
  `cctf_mode_for("ProPhoto RGB") == 1`),所以读回来必须用 **ProPhoto 曲线**(mode 1)解码。

用错的后果分两种:

- 用 sRGB 曲线解 ProPhoto:画面**看起来差不多**,但中调偏移、阴影发灰。安静的错误。
- 少了解码这一步(直接当线性用):双重编码,画面**压到近乎全黑**。响亮的错误。

画布的 shader(`ios/SpektraLab/Canvas/Canvas.metal`)照抄了引擎的
`cctf_decode_mode` / `cctf_encode_mode`,连断点 `0.040449936` 都用引擎的那个值。

## 引擎的输出契约

- 纹理的格式是 `RGBA16Unorm`(`metal_gpu.cpp:680`)。
- `spk_result.row_stride_px` 的单位是**像素**,不是字节,而且每像素是 **4 个 uint16**(RGBA)。
  安卓版在这里翻过车:消费端写成 `rgba16 + y * stride` 会让每行只前进 1/4 行,导出成片横向错乱。
  正确写法是 `rgba16 + y * stride * 4`。
- iOS 端不用这个指针:纹理的存储是私有的,读不出来,只能 blit 到一个 shared `MTLBuffer`。
  blit 的行间距是 `bytesPerRow`(我们填 `width * 8`),所以 CPU 侧的索引是 `y * width + x`。
- 引擎原本创建的纹理只有 `MTLTextureUsageShaderRead`,**没有 `CopySource`**。Metal 不允许从
  没有 `CopySource` 的纹理里 blit 出来。macOS 版不暴露这个问题,因为它是把纹理*画*出来
  而不是*读*出来。

## 为什么自己写 Xcode 工程

上游的 macOS 工程是 `Tools/gen-project.py` 生成的 pbxproj,不是 Xcode 手写后提交的。
这个仓库沿用同一套做法(`ios/Tools/gen-project.py`),理由一样:

- 工程文件从磁盘状态派生,**加一个源文件不可能被忘记**
- 它是一个可以 review 的 diff,而不是 Xcode 恰好写出来的东西
- 对象 id 由**相对路径**的 sha1 派生,所以两个 checkout 一致,worktree 重新生成不冲突
- **可以在没有 Mac 的机器上改工程**——这正是本项目需要的

`gen-project.py` 也因此是 CI 的一步:CI 重新生成工程,构建的是磁盘上的东西,不是提交上来的。

## 为什么引擎是源码而不是静态库

引擎的 C++ 直接进 app target 的 Compile Sources,和 macOS 版一样。
一个单独的静态库 target 在这里唯一多出来的东西,是**第二处 include 路径会漂移的地方**。

排除掉的三个目录和三个文件,原因各不相同:

| 排除 | 原因 |
|---|---|
| `src/io/` | Windows 主机的 LibRaw / 原生 TIFF I/O。iOS 用 ImageIO 解码 |
| `src/desktop/` | 桌面控制器 |
| `src/gpu/vulkan_gpu.cpp` | Vulkan 后端。iOS 是 Metal |
| `src/pipeline/windows_unported.cpp` | Windows 专用的桩 |
| `src/pipeline/imprint_raster.cpp` | 非 Apple 的印字光栅器。Apple 路径在 `overscan.cpp` 里用 CoreText |

## 引擎补丁的三处改动

`tools/apply-ios-patch.py`。每一处都先断言命中次数,全部命中才写盘,并且检查
`#if`/`#endif` 是否平衡——一个悄悄没打上的补丁会在很远的地方以"引擎 bug"的样子炸掉。

1. **内存压力监控**:`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` 在 iOS SDK 里不存在。
   不改就是编译不过。共用同一个队列的 idle timer 是普通 timer,在 iOS 上照常工作,所以
   只有 pressure 那一半是条件编译的,队列本身保持无条件。
2. **结果纹理的 `CopySource`**:见上面"引擎的输出契约"。
3. **`GPUFamilyMac2`**:iOS 没有这个 family。`supportsFamily(Mac2)` 在 iOS 上返回 false,
   所以不改也不会错,只是问了个平台上不存在的问题。

## 打包的三个容易忘的点

1. **safe-math 不是可选的**。引擎在启动时探测 metallib,发现 fast-math 漂移就拒绝运行
   (RFC-014 §5.1 trap 1,`exp` 和 fma 收缩带来 1.1e-5 的偏差)。所以引擎的 kernel 由
   `ios/Tools/build-engine.sh` 用 `xcrun -sdk iphoneos metal` **单独编译**,带
   `-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise`,不走 Xcode。
   Xcode 的 `MTL_FAST_MATH = YES` 只影响 app 自己的 canvas shader。

2. **`.metallib` 要编给 iOS,不是 macOS**。`xcrun -sdk iphoneos metal` 用的是 iOS SDK
   和 iOS GPU family 的能力集;用 macOS 的编出来虽然能加载,但缺了 iOS 编译器会丢掉的东西。

3. **资源是相对路径解析的**。引擎把 `resources_dir` 拼到每个资源上
   (`profiles/<stock>.json`、`spektrafilm_constants.bin`、`io/sRGB.icc`),所以
   `resources_dir` 必须是**包含**这些文件的目录,而不是文件本身。iOS 端是
   `Bundle.main.resourceURL/engine`。

## 一个还没验证的假设

引擎的输出纹理的**行间距**在 blit 之后,CPU 侧按 `y * width + x` 索引。
这依赖 `MTL::TextureDescriptor` 加上 `bytesPerRow = row_stride_px * 8` 之后,blit
`destinationBytesPerRow = width * 8` 确实给出紧密排列的行。

这是**推断**,不是验证过的。真机第一次导出时,应该拿一张有清晰水平线条的照片
(比如建筑的地平线),看导出图有没有斜的条纹。有的话,行间距就是 `row_stride_px * 8` 字节,
索引要改成 `y * row_stride_px + x`。
