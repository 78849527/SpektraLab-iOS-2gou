//  ImageDecoder.swift — a photo in, the engine's pixels out.
//
//  iOS has no LibRaw: the engine's own `io/raw_decoder.cpp` is the Windows
//  path, and the macOS app decodes with Core Image. This file does the same
//  thing for iOS, and it has to do one thing Core Image does not do for free.
//
//  **The engine wants ProPhoto RGB, linear.** Core Image converts directly
//  from the source profile into the same calibrated float working space used
//  by Mac 1.3.5. There is deliberately no 8-bit sRGB intermediate.
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

/// A decoded frame, in the engine's input space.
struct DecodedFrame {
    /// Tightly packed float32, three channels, top row first.
    let pixels: [Float]
    let width: Int
    let height: Int

    var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// Why a frame could not be decoded.
enum DecodeError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupportedFormat(String)
    case emptyImage
    case outOfMemory(pixels: Int)

    var description: String {
        switch self {
        case .unreadable(let why): "the image could not be read: \(why)"
        case .unsupportedFormat(let what): "this format cannot be decoded on iOS: \(what)"
        case .emptyImage: "the image is empty"
        case .outOfMemory(let px): "this frame is \(px) pixels, too large to decode on a phone"
        }
    }
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
    static let maxPixels = 64_000_000

    /// The long edge the decoded frame is scaled to before it reaches the
    /// engine.
    ///
    /// A preview at 2048 px long edge needs no more, and decoding a 45 MP
    /// frame to throw most of it away costs seconds and hundreds of megabytes
    /// for a result nobody sees. The export path decodes at full size.
    static let previewLongEdge = 2048

    /// Export at the source resolution; only the interactive preview shrinks.
    static let exportLongEdge: Int? = nil

    /// The exact float working space used by the Mac 1.3.5 decoder.
    private static let linearProPhoto: CGColorSpace? = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,
            0.1351917, 0.7118741, 0.0000000,
            0.0313534, 0.0000857, 0.8252100,
        ]
        return d50.withUnsafeBufferPointer { wp in
            black.withUnsafeBufferPointer { bp in
                gamma.withUnsafeBufferPointer { gp in
                    primaries.withUnsafeBufferPointer { matrix in
                        CGColorSpace(calibratedRGBWhitePoint: wp.baseAddress!,
                                     blackPoint: bp.baseAddress,
                                     gamma: gp.baseAddress!,
                                     matrix: matrix.baseAddress)
                    }
                }
            }
        }
    }()

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])

    /// Decode an image from data.
    ///
    /// - Parameter maxLongEdge: the long edge to scale to, or `nil` for no
    ///   scaling (the export path).
    static func decode(data: Data, maxLongEdge: Int?, typeHint: UTType? = nil) throws -> DecodedFrame {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DecodeError.unreadable("not an image this system recognises")
        }

        // CIRAWFilter can return a non-nil implementation for ordinary JPEGs
        // on some iOS releases. Its Swift properties are also not guaranteed
        // to have Objective-C setters on every concrete implementation; a
        // setter then raises an exception that Swift cannot catch. Trust the
        // container type reported by ImageIO and leave the RAW filter at its
        // supported defaults.
        if isRAW(source: source, typeHint: typeHint) {
            let suffix = typeHint?.preferredFilenameExtension ?? "raw"
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(suffix)
            try data.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard let raw = CIRAWFilter(imageURL: temporaryURL) else {
                throw DecodeError.unsupportedFormat(typeHint?.identifier ?? "camera RAW")
            }
            // Match Mac 1.3.5's linear RAW look. These setters are only used
            // after ImageIO has positively identified a camera RAW container;
            // ordinary JPEGs never construct a CIRAWFilter.
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
            raw.isDraftModeEnabled = false
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.isGamutMappingEnabled = false
            raw.localToneMapAmount = 0
            raw.extendedDynamicRangeAmount = 0
            guard let output = raw.outputImage else {
                throw DecodeError.unreadable("the RAW decoder produced no image")
            }
            return try pixels(from: output, maxLongEdge: maxLongEdge)
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw DecodeError.unreadable("Core Image could not decode this image")
        }
        return try pixels(from: image, maxLongEdge: maxLongEdge)
    }

    /// ImageIO's declared container type is the gate for camera RAW handling.
    /// This intentionally does not infer RAW support from CIRAWFilter alone.
    static func isRAW(source: CGImageSource, typeHint: UTType? = nil) -> Bool {
        if typeHint?.conforms(to: .rawImage) == true { return true }
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// Decode an image from a file URL.
    static func decode(url: URL, maxLongEdge: Int?) throws -> DecodedFrame {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let hint = UTType(filenameExtension: url.pathExtension)
        return try decode(data: data, maxLongEdge: maxLongEdge, typeHint: hint)
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
        return try pixels(from: CIImage(cgImage: image), maxLongEdge: nil)
    }

    /// Decode from a `CGImage`.
    static func decode(cgImage: CGImage, maxLongEdge: Int?) throws -> DecodedFrame {
        try pixels(from: CIImage(cgImage: cgImage), maxLongEdge: maxLongEdge)
    }

    // MARK: - the decode itself

    /// Core Image performs the complete source-profile conversion directly
    /// into float32 linear ProPhoto, matching Mac 1.3.5 without an 8-bit sRGB
    /// intermediate or a hand-written colour matrix.
    private static func pixels(from source: CIImage, maxLongEdge: Int?) throws -> DecodedFrame {
        guard let colorSpace = linearProPhoto else {
            throw DecodeError.unreadable("linear ProPhoto RGB is unavailable")
        }
        var image = source
        let sourceExtent = image.extent
        guard !sourceExtent.isInfinite, !sourceExtent.isEmpty else {
            throw DecodeError.emptyImage
        }
        if let maxLongEdge {
            let current = max(sourceExtent.width, sourceExtent.height)
            if current > CGFloat(maxLongEdge), current.isFinite {
                let factor = CGFloat(maxLongEdge) / current
                image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            }
        }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw DecodeError.emptyImage }
        guard width * height <= maxPixels else {
            throw DecodeError.outOfMemory(pixels: width * height)
        }
        let placed = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                              y: -extent.origin.y))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(placed, toBitmap: base, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: colorSpace)
        }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return DecodedFrame(pixels: rgb, width: width, height: height)
    }

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

}
