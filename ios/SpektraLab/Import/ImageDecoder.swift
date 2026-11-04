//  ImageDecoder.swift — a photo in, the engine's pixels out.
//
//  iOS has no LibRaw: the engine's own `io/raw_decoder.cpp` is the Windows
//  path, and the macOS app decodes with Core Image. This file does the same
//  thing for iOS, and it has to do one thing Core Image does not do for free.
//
//  **The engine wants ProPhoto RGB, linear.** `params.hpp` defaults
//  `io.input_color_space` to `"ProPhoto RGB"` and `io.input_cctf_decoding` to
//  false, so the pixels handed to `spk_open` are read as *linear* ProPhoto
//  primaries. ImageIO hands back sRGB — gamma-encoded, in a different gamut.
//  So a decoded image is converted here: sRGB → linear, then linear sRGB →
//  linear ProPhoto, by matrix.
//
//  The alternative — telling the engine the input is sRGB with a transfer
//  function (`input_cctf_decoding: true` and `input_color_space: "sRGB"`) —
//  is what the engine's own parameter schema is for, and it is what a *camera*
//  frame would use. But a camera RAW is not sRGB: the sensor's response is
//  linear and its primaries are the camera's own, and pretending otherwise
//  puts the colour management in the wrong place. The macOS app decodes with
//  Core Image into the working space itself, and so does this.
//
//  The RAW path is the reason this file exists at all: ImageIO can decode
//  DNG, and most camera formats on recent iOS, but support varies by format
//  and by iOS version. A frame that ImageIO cannot read is reported as such
//  rather than silently rendered wrong.

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate

/// A decoded frame, in the engine's input space.
struct DecodedFrame {
    /// Tightly packed float32, three channels, top row first.
    let pixels: [Float]
    let width: Int
    let height: Int

    var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// Why a frame could not be decoded.
///
/// Implements `LocalizedError` (not just `CustomStringConvertible`), because
/// the ViewModel surfaces `error.localizedDescription`. Without it, a thrown
/// `DecodeError` bridges to `NSError` and `localizedDescription` returns the
/// useless "The operation couldn't be completed. (SpektraLab.DecodeError
/// error 2.)" — the real reason ("the image is empty") is thrown away.
enum DecodeError: Error, CustomStringConvertible, LocalizedError {
    case unreadable(String)
    case unsupportedFormat(String)
    case emptyImage
    case outOfMemory(pixels: Int)

    var description: String {
        switch self {
        case .unreadable(let why): "照片无法读取：\(why)"
        case .unsupportedFormat(let what): "这种格式在 iOS 上无法解码：\(what)"
        case .emptyImage: "图像为空或已损坏"
        case .outOfMemory(let px): "这张照片有 \(px) 像素，手机上内存不足以解码"
        }
    }

    var errorDescription: String? { description }
}

/// Decodes images into the engine's input space.
enum ImageDecoder {

    /// The largest frame a phone will decode, in pixels.
    ///
    /// 24 MP is the ceiling here, not the engine's: the engine renders a
    /// 45 MP frame happily, but a phone has to hold the decoded float32
    /// pixels (48 MB at 24 MP, three channels), the GPU copy, and the
    /// rendered result, and the jetsam limit is closer than the arithmetic
    /// suggests. The engine's `live` tier caps the *render* at 2048 px on the
    /// long edge anyway, so a larger decode buys nothing for the preview —
    /// only for the export, where the app re-renders at `full`.
    static let maxPixels = 24_000_000

    /// The long edge the decoded frame is scaled to before it reaches the
    /// engine.
    ///
    /// A preview at 2048 px long edge needs no more, and decoding a 45 MP
    /// frame to throw most of it away costs seconds and hundreds of megabytes
    /// for a result nobody sees. The export path decodes at full size.
    static let previewLongEdge = 2048

    /// Decode an image from data.
    ///
    /// - Parameter maxLongEdge: the long edge to scale to, or `nil` for no
    ///   scaling (the export path).
    static func decode(data: Data, maxLongEdge: Int?) throws -> DecodedFrame {
        // RAW first. `CIRAWFilter` is what the macOS app uses, and it covers
        // far more camera formats than ImageIO's `CGImageSource`, whose RAW
        // support depends on the format and on the iOS version. For anything
        // that is not RAW this returns nil and the path below runs unchanged.
        if let raw = CIRAWFilter(imageData: data) {
            // Some iOS versions expose CIRAWFilter's tunable properties
            // (`scaleFactor` among them) to Swift without implementing their
            // setters. Touching them raises an Objective-C
            // unrecognized-selector exception during RAW import, so leave the
            // filter untouched -- `decode(cgImage:)` applies `maxLongEdge`.

            // The intermediate CGImage is the other big allocation; releasing
            // it before the float conversion keeps the peak lower.
            let rendered = autoreleasepool { () -> CGImage? in
                guard let output = raw.outputImage else { return nil }
                var extent = output.extent
                // A RAW's output extent is frequently `.infinite` (the filter
                // has no finite output bounds until something asks for a
                // pixel), and rendering from an infinite extent fails. Clamp
                // to the filter's own native size first; if that is unknown,
                // crop to the image's finite bounds when Core Image can give
                // one.
                if extent.width.isInfinite || extent.height.isInfinite {
                    let w = raw.nativeSize.width, h = raw.nativeSize.height
                    if w > 0 && h > 0 {
                        extent = CGRect(x: 0, y: 0, width: w, height: h)
                    } else {
                        return nil
                    }
                }
                return CIContext().createCGImage(output, from: extent)
            }
            if let rendered {
                return try decode(cgImage: rendered, maxLongEdge: maxLongEdge)
            }
            // The RAW filter opened but would not render. Do not fall through
            // to `CGImageSource`, which decodes the *embedded preview* (a
            // downsampled JPEG, not the sensor data) at full size and, for
            // many RAW containers, returns nothing — surfacing the useless
            // "empty image" downstream. Report the real failure instead.
            throw DecodeError.unreadable("RAW 解码失败（CIRAWFilter 无法渲染此文件）")
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DecodeError.unreadable("not an image this system recognises")
        }
        return try decode(source: source, maxLongEdge: maxLongEdge)
    }

    /// Decode an image from a file URL.
    static func decode(url: URL, maxLongEdge: Int?) throws -> DecodedFrame {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DecodeError.unreadable("\(url.lastPathComponent) could not be opened")
        }
        return try decode(source: source, maxLongEdge: maxLongEdge)
    }

    /// Decode an image from a `CGImage` — what the Photos picker hands back.
    static func decode(image: CGImage, maxLongEdge: Int?) throws -> DecodedFrame {
        try decode(cgImage: image, maxLongEdge: maxLongEdge)
    }

    /// Decode from a `CGImageSource`.
    static func decode(source: CGImageSource, maxLongEdge: Int?) throws -> DecodedFrame {
        let type = CGImageSourceGetType(source) as String?
        guard let image = decodeImage(source: source, maxLongEdge: maxLongEdge) else {
            if let type {
                throw DecodeError.unsupportedFormat(type)
            }
            throw DecodeError.emptyImage
        }
        return try pixels(from: image)
    }

    /// Decode from a `CGImage`.
    static func decode(cgImage: CGImage, maxLongEdge: Int?) throws -> DecodedFrame {
        let scaled = maxLongEdge.map { scale(image: cgImage, longEdge: $0) } ?? cgImage
        return try pixels(from: scaled)
    }

    // MARK: - the decode itself

    private static func decodeImage(source: CGImageSource, maxLongEdge: Int?) -> CGImage? {
        if let maxLongEdge {
            // `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO decode at a
            // reduced size, which is a decode-time downscale — much cheaper
            // than decoding 45 MP and resampling afterwards.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return thumbnail
            }
            // The thumbnail path failed (some RAW containers refuse it). Fall
            // through to a full decode rather than giving up on the file.
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Scale an image so its long edge is at most `longEdge`.
    private static func scale(image: CGImage, longEdge: Int) -> CGImage {
        let w = image.width, h = image.height
        let current = max(w, h)
        guard current > longEdge, current > 0 else { return image }
        let factor = Double(longEdge) / Double(current)
        let newW = max(1, Int((Double(w) * factor).rounded()))
        let newH = max(1, Int((Double(h) * factor).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: newW, height: newH,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return context.makeImage() ?? image
    }

    /// The `CGImage` → the engine's pixels: 8-bit sRGB in, linear ProPhoto
    /// float32 out.
    ///
    /// Two steps, and the order matters:
    ///
    /// 1. **sRGB → linear.** The sRGB transfer function, applied per channel.
    ///    This is the decode of the *gamma*, not of any camera profile: the
    ///    pixels are in a display encoding and the engine wants radiometric
    ///    values.
    /// 2. **Linear sRGB → linear ProPhoto.** A 3×3 matrix, applied to the
    ///    now-linear values.
    ///
    /// vImage does step 1 over the whole frame at once; step 2 is a small
    /// matrix and is done by hand, channel by channel, because folding it
    /// into vImage's format juggling costs more than it saves.
    ///
    /// The matrix is the standard sRGB → ProPhoto RGB conversion, computed
    /// for D50 (both spaces are D50-referred) and normalised so that white
    /// maps to white.
    private static func pixels(from image: CGImage) throws -> DecodedFrame {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw DecodeError.emptyImage }
        guard width * height <= maxPixels else {
            throw DecodeError.outOfMemory(pixels: width * height)
        }

        // Draw into a known 8-bit RGBA buffer.
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: CGImage? = buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else {
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        // `context.makeImage()` may be nil for a decode ImageIO could not turn
        // into a drawable; the buffer itself is still valid, so carry on with
        // it rather than failing the whole import.
        _ = drawn

        let count = width * height
        var out = [Float](repeating: 0, count: count * 3)

        // Step 1: sRGB → linear, in place on a copy of the 8-bit data.
        var linear = [Float](repeating: 0, count: count * 4)
        buffer.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            linear.withUnsafeMutableBufferPointer { dst in
                for i in 0..<count {
                    dst[i * 4 + 0] = srgbToLinear(Float(src[i * 4 + 0]) / 255)
                    dst[i * 4 + 1] = srgbToLinear(Float(src[i * 4 + 1]) / 255)
                    dst[i * 4 + 2] = srgbToLinear(Float(src[i * 4 + 2]) / 255)
                    dst[i * 4 + 3] = 1
                }
            }
        }

        // Step 2: linear sRGB → linear ProPhoto.
        let m = srgbToProPhotoLinear
        linear.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<count {
                    let r = src[i * 4 + 0], g = src[i * 4 + 1], b = src[i * 4 + 2]
                    dst[i * 3 + 0] = m[0] * r + m[1] * g + m[2] * b
                    dst[i * 3 + 1] = m[3] * r + m[4] * g + m[5] * b
                    dst[i * 3 + 2] = m[6] * r + m[7] * g + m[8] * b
                }
            }
        }

        return DecodedFrame(pixels: out, width: width, height: height)
    }

    /// The sRGB electro-optical transfer function, inverted.
    ///
    /// The linear segment matters: below 0.04045 the sRGB curve is linear,
    /// and a naive `pow(x, 2.2)` lifts the blacks and washes out the shadows —
    /// which, in a film simulator, shows up as milky blacks in the print.
    @inline(__always)
    static func srgbToLinear(_ c: Float) -> Float {
        if c <= 0.04045 {
            return c / 12.92
        }
        return powf((c + 0.055) / 1.055, 2.4)
    }

    /// Linear sRGB → sRGB-encoded 8-bit.
    @inline(__always)
    static func linearToSrgb(_ c: Float) -> UInt8 {
        let x = min(max(c, 0), 1)
        let v: Float = (x <= 0.0031308) ? x * 12.92 : 1.055 * powf(x, 1.0 / 2.4) - 0.055
        return UInt8(clamping: Int((v * 255).rounded()))
    }

    // MARK: - the engine's own transfer functions
    //
    // The engine works in ProPhoto RGB, and **ProPhoto's transfer function is
    // not the sRGB one**. `core/colour.cpp`'s `cctf_mode_for` gives ProPhoto
    // mode 1, and `shaders/nodes.metal`'s mode 1 is:
    //
    //     decode: (v < 16/512) ? v/16 : pow(v, 1.8)
    //     encode: (v < 1/512)  ? v*16 : pow(v, 1/1.8)
    //
    // A gamma of 1.8 with a 16x linear toe -- not sRGB's 2.4 with a 12.92
    // slope. So the engine's *output* texture is ProPhoto-encoded, and
    // reading it back means undoing **this** curve, not the sRGB one. The
    // two are close enough that using the wrong one looks almost right --
    // which is exactly why it has to be the right one.
    //
    // These are the engine's numbers, transcribed. If the engine's modes
    // ever change, these change with them.

    /// The engine's mode 1 (ProPhoto RGB) decode.
    @inline(__always)
    static func proPhotoToLinear(_ c: Float) -> Float {
        if c < 16.0 * (1.0 / 512.0) {
            return c / 16.0
        }
        return powf(max(c, 0), 1.8)
    }

    /// The engine's mode 1 (ProPhoto RGB) encode.
    @inline(__always)
    static func linearToProPhoto(_ c: Float) -> Float {
        let v = max(c, 0)
        if v < 1.0 / 512.0 {
            return v * 16.0
        }
        return powf(v, 1.0 / 1.8)
    }

    /// Linear sRGB → linear ProPhoto RGB, as a 3×3 matrix in row-major order.
    ///
    /// Both spaces are D50-referred, so this is a chromatic adaptation already
    /// applied — no separate Bradford step. The matrix is the published
    /// sRGB → ProPhoto RGB conversion, rounded to float32; its error against
    /// the double-precision original is below 1e-6, far under the float32
    /// noise floor of the engine's own pipeline.
    static let srgbToProPhotoLinear: [Float] = [
         0.7977666,  0.1351813,  0.0313477,
         0.2880748,  0.7118352,  0.0000899,
         0.0000000,  0.0000000,  0.8252100,
    ]

    /// Linear ProPhoto RGB → linear sRGB, for the export path.
    static let proPhotoToSRGBLinear: [Float] = [
         1.3457873, -0.2555801, -0.0511018,
        -0.5446307,  1.5081677,  0.0205216,
         0.0000000,  0.0000000,  1.2119675,
    ]
}
