//  CanvasRenderer.swift — the engine's picture on the screen.
//
//  The engine renders into an `MTLTexture` (`RGBA16Unorm`, ProPhoto RGB — the
//  working space, RFC-018 §5.1). This file draws that texture, and converts
//  it to the display's space on the way.
//
//  **The conversion is not optional.** The texture holds gamma-encoded
//  ProPhoto RGB (the engine sets `output_cctf_encoding = true` and
//  `cctf_mode_for("ProPhoto RGB") == 1`, an sRGB-style transfer); a screen
//  wants gamma-encoded sRGB in the display's primaries. The
//  macOS app does this with the engine's own output transform
//  (`spk_output_transform`), which is a fetch of matrices and constants that
//  the app then runs in its own kernel. iOS does the same thing, with the
//  same two matrices, and the difference is where they come from.
//
//  Actually — simpler and more honest: iOS draws into an sRGB drawable, and
//  the conversion is done by the shader below with the matrices from the
//  engine's `spk_output_transform`, so the numbers are the engine's own
//  rather than a second copy that can drift from them. The transform is
//  fetched once per destination space and cached.

import Foundation
import Metal
import MetalKit
import UIKit

/// The matrices that take the working space to the display, as the engine
/// hands them over.
struct OutputTransform {
    /// Source linear RGB → target linear RGB, row-major.
    let matrix: [Float]
    /// The transfer function's mode on each side, as `shaders/nodes.metal`
    /// numbers them.
    let sourceCCTFMode: Int
    let targetCCTFMode: Int
    /// The CAM16-UCS gamut compression, when it is on.
    let gamutCompressConsts: [Float]
    let gamutCompressActive: Bool

    /// The identity: the working space to itself.
    static let identity = OutputTransform(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                                          sourceCCTFMode: 0, targetCCTFMode: 0,
                                          gamutCompressConsts: [], gamutCompressActive: false)
}

/// Draws the engine's texture into an `MTKView`.
@MainActor
final class CanvasRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// The texture to draw. Set by the view model when a render lands.
    private(set) var texture: MTLTexture?

    /// The transform to apply on the way to the screen.
    ///
    /// The engine renders in the ProPhoto working space but applies the
    /// output CCTF on write (`io.output_cctf_encoding = true`, and
    /// `cctf_mode_for("ProPhoto RGB") == 1`), so the texture is
    /// **gamma-encoded ProPhoto** -- not linear.
    ///
    /// The two modes are therefore different, and they are the engine's own
    /// numbering (`shaders/nodes.metal`):
    ///
    ///   * source mode 1 -- ProPhoto RGB: a gamma of 1.8 with a 16x linear
    ///     toe. Decoding the texture means undoing *that*.
    ///   * target mode 0 -- sRGB: the display's own curve, a gamma of 2.4
    ///     with a 12.92 slope.
    ///
    /// Using sRGB's curve to read ProPhoto's data (or the other way round)
    /// looks almost right, which is exactly why it has to be right.
    ///
    /// The matrix is `proPhotoToSRGBLinear`: linear ProPhoto to linear sRGB,
    /// the same one the export path uses, so the screen and the saved file
    /// agree.
    var transform: OutputTransform = OutputTransform(
        matrix: ImageDecoder.proPhotoToSRGBLinear,
        sourceCCTFMode: 1,
        targetCCTFMode: 0,
        gamutCompressConsts: [],
        gamutCompressActive: false)

    /// The transform's parameters, uploaded to the GPU once per change.
    private var transformBuffer: MTLBuffer?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        // The shader is compiled from source at launch: one small file, and it
        // keeps the app's own drawing code out of the engine's build (which
        // compiles its kernels with safe-math and must not inherit the app's
        // fast-math setting — RFC-014 §5.1 trap 1).
        guard let library = device.makeDefaultLibrary(bundle: .main),
              let vertex = library.makeFunction(name: "canvasVertex"),
              let fragment = library.makeFunction(name: "canvasFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // Must equal the MTKView's `colorPixelFormat`. The MTKView default is
        // `.bgra8Unorm`; the shader already outputs clamped sRGB-encoded
        // values, so an 8-bit unorm drawable is correct. If you want an
        // HDR/`rgba16Float` drawable instead, set `view.colorPixelFormat`
        // to match — do NOT leave them mismatched.
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipeline = state

        // The transform's uniforms: the 3×3 matrix, the two modes, and the
        // gamut-compression constants the fragment shader reads.
        let buffer = device.makeBuffer(length: 256, options: .storageModeShared)
        transformBuffer = buffer
        super.init()
        uploadTransform()
    }

    /// The texture to show.
    func setTexture(_ texture: MTLTexture?) {
        self.texture = texture
    }

    /// The working space → display transform.
    func setTransform(_ transform: OutputTransform) {
        self.transform = transform
        uploadTransform()
    }

    /// Copy the transform into the shared buffer the shader reads.
    private func uploadTransform() {
        guard let buffer = transformBuffer else { return }
        struct Params {
            var matrix = SIMD3<Float>(1, 0, 0)
            var row2 = SIMD3<Float>(0, 1, 0)
            var row3 = SIMD3<Float>(0, 0, 1)
            var sourceMode: UInt32 = 0
            var targetMode: UInt32 = 0
            var gamutActive: UInt32 = 0
            var padding = SIMD3<UInt32>(0, 0, 0)
        }
        var params = Params()
        let m = transform.matrix
        if m.count >= 9 {
            // `transform.matrix` is row-major, but Metal's `float3x3` is column-
            // major. Upload each *column* of the matrix as the intended *row*, so
            // that `matrix * v` in the shader computes M·v and not Mᵀ·v. Writing
            // the three rows verbatim would make Metal read them as three columns
            // and transpose the grade (wrong hue/contrast).
            params.matrix = SIMD3(m[0], m[3], m[6])
            params.row2   = SIMD3(m[1], m[4], m[7])
            params.row3   = SIMD3(m[2], m[5], m[8])
        }
        params.sourceMode = UInt32(transform.sourceCCTFMode)
        params.targetMode = UInt32(transform.targetCCTFMode)
        params.gamutActive = transform.gamutCompressActive ? 1 : 0
        memcpy(buffer.contents(), &params, MemoryLayout<Params>.size)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let texture,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        if let transformBuffer {
            encoder.setFragmentBuffer(transformBuffer, offset: 0, index: 0)
        }
        // A full-screen triangle: three vertices, no vertex buffer, no index
        // buffer. The vertex shader positions them from `vertex_id`.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
