//  ViewModel.swift — the app's state, and the loop that drives the engine.
//
//  One `ObservableObject` holds the whole app: the frame, the stocks, the
//  parameters, the rendered texture, and the errors. SwiftUI reads it; the
//  engine is driven from it.
//
//  **The render loop is the interesting part.** A slider drag must not queue
//  a hundred renders: the engine would work through them all after the finger
//  is already up, and the user would watch the preview lag behind their own
//  hand. So a change marks the render *stale*, and a render runs only when
//  the user stops moving — with one render in flight at a time, and a newer
//  request replacing an older one rather than queueing behind it.

import Foundation
import SwiftUI
import Metal
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ViewModel: ObservableObject {

    // MARK: - what the app shows

    /// The app's state.
    ///
    /// Named `AppState` rather than `State`: inside a SwiftUI view, `State`
    /// is SwiftUI's own property-wrapper type, and a nested type of the same
    /// name makes every `.failed` in the file ambiguous -- the compiler
    /// resolves it to some other `State` in scope and reports a type error
    /// about a gesture phase, which is nowhere near the problem.
    enum AppState: Equatable {
        case empty
        case importing
        case rendering
        case ready
        case failed(String)
    }

    @Published private(set) var state: AppState = .empty
    @Published private(set) var statusText = ""
    @Published private(set) var renderedTexture: MTLTexture?

    /// What identifies the current render.
    ///
    /// The engine gives every render a progress id, and it is a new string
    /// each time -- so it is what tells SwiftUI that the picture changed.
    /// The texture itself cannot: `MTLTexture` is not `Hashable`, and its
    /// `hashValue` does not exist.
    @Published private(set) var renderIdentity: String = ""
    @Published private(set) var lastRenderMs: Double = 0
    @Published private(set) var sourceSize: CGSize = .zero

    /// The parameters, as the sliders hold them.
    @Published var params: [String: Double] = [:]
    /// The chosen film and paper.
    @Published var filmStock: String = StockCatalog.defaultFilm
    @Published var printStock: String = StockCatalog.defaultPaper

    /// The catalogue, read at launch.
    @Published private(set) var catalog = StockCatalog(films: [], papers: [], slides: [])

    /// The picked photo, kept so it can be re-decoded at full size for export.
    private var pickedItem: PhotosPickerItem?
    /// The original bytes of the picked photo, kept for export.
    ///
    /// `PhotosPickerItem.loadTransferable` does not guarantee it returns the
    /// same bytes on every call — for a RAW it may hand back the raw sensor
    /// data the first time and a transcoded image the second. Re-loading for
    /// export is what made a photo that previewed fine fail the full-size
    /// decode. Keep the bytes from the import, where they already decoded
    /// once, and reuse them.
    private var pickedData: Data?
    private var pickedImage: UIImage?

    /// The decoded frame in the engine's input space.
    private var frame: DecodedFrame?

    // MARK: - the engine

    private var engine: SpektraEngine?
    /// The canvas renderer. The view needs it to draw the texture.
    private(set) var renderer: CanvasRenderer? = nil
    private var device: MTLDevice?

    /// The render loop's state.
    private var renderTask: Task<Void, Never>?
    private var renderInFlight = false
    private var needsRender = false
    private var paramsDirty = false

    // MARK: - life cycle

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .failed("这台设备没有可用的 Metal 设备")
            return
        }
        self.device = device

        // The catalogue and the defaults, before the engine: a stock list that
        // depends on the engine's resources is a stock list that is empty when
        // the resources are missing, and an empty list is harder to diagnose
        // than an error.
        let resources = SpektraEngine.defaultResources()
        catalog = StockCatalog.load(resources: resources)

        for control in ParamCatalog.all {
            params[control.key] = control.defaultValue
        }

        do {
            let engine = try SpektraEngine(device: device, resources: resources)
            self.engine = engine
            self.renderer = CanvasRenderer(device: device)
            state = .empty
            statusText = "就绪 · \(catalog.films.count) 款胶片 · \(catalog.papers.count) 款相纸"
            reportPreviousCrash()
        } catch {
            // The CI build does not ship the resource archive inside the .app:
            // a 15 MB payload makes the side-loading installer fail when it
            // copies the unpacked IPA to its fixed `App.app`, and it reports
            // only "Failed to get bundle ID". The six-entry test bundle
            // installed fine, so the archive is fetched here once instead.
            state = .importing
            statusText = "首次启动：正在准备引擎资源…"
            Task { @MainActor in
                await self.prepareResourcesAndStart(device: device)
            }
        }
    }

    /// First-launch path: download the resources, unpack them, start the
    /// engine. Every launch after that finds the unpacked copy in Caches and
    /// never reaches the network.
    private func prepareResourcesAndStart(device: MTLDevice) async {
        do {
            let resources = try await SpektraEngine.fetchResourcesRemotely()
            catalog = StockCatalog.load(resources: resources)
            let engine = try SpektraEngine(device: device, resources: resources)
            self.engine = engine
            self.renderer = CanvasRenderer(device: device)
            state = .empty
            statusText = "就绪 · \(catalog.films.count) 款胶片 · \(catalog.papers.count) 款相纸"
            reportPreviousCrash()
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "资源准备失败"
        }
    }

    /// Puts the previous run's crash on screen, so it does not take another
    /// cycle of "it just closes" to find out what happened.
    private func reportPreviousCrash() {
        guard let crash = CrashLog.take() else { return }
        state = .failed("上次异常退出：\(crash)")
        statusText = "上次异常退出 · \(crash)"
    }

    // MARK: - importing

    /// Take a photo from the library.
    func importPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        pickedItem = item
        state = .importing
        statusText = "正在读取照片…"

        do {
            guard let data = try await item.loadTransferable(type: PickedImageData.self)?.data else {
                throw DecodeError.unreadable("照片没有返回数据")
            }
            // Keep the bytes that already decoded once, so export does not
            // re-request them and get a different (possibly undecodable)
            // representation back.
            pickedData = data
            // The preview decode is small: the live tier renders at 2048 px on
            // the long edge, so a bigger decode buys nothing and costs
            // seconds and hundreds of megabytes.
            let decoded = try ImageDecoder.decode(data: data, maxLongEdge: ImageDecoder.previewLongEdge)
            try await loadFrame(decoded)
            statusText = "已载入 \(decoded.width)×\(decoded.height) · \(String(format: "%.1f", decoded.megapixels)) MP"
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "导入失败"
        }
    }

    /// Load an already-decoded frame: open a session and render the first
    /// preview.
    private func loadFrame(_ decoded: DecodedFrame) async throws {
        guard let engine else { throw EngineError.failed(status: -1, message: "引擎没有启动") }
        frame = decoded
        sourceSize = CGSize(width: decoded.width, height: decoded.height)

        // Open with the current stocks and parameters, so the first preview
        // already shows what the user chose.
        var delta = ParamDefaults.delta(film: filmStock, paper: printStock)
        for (key, value) in params { delta[key] = .number(value) }

        // The pointer has to stay alive across the `open` call: the engine
        // borrows the pixels for the duration of that call and copies what it
        // keeps, so the buffer must not go out of scope before it returns.
        // Taking the address inside a closure and using it outside would
        // leave it dangling -- which reads as a frame of noise rather than
        // as a crash, and is much harder to find.
        let reply: OpenReply = try decoded.pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                throw EngineError.failed(status: -1, message: "解码结果为空")
            }
            return try engine.open(pixels: EnginePixels(
                data: base,
                width: decoded.width,
                height: decoded.height), params: delta)
        }

        if let meta = reply.meta, let w = meta.width, let h = meta.height {
            sourceSize = CGSize(width: w, height: h)
        }

        // The solve must happen before the first render, or the print uses
        // default exposure and the highlights blow out — which looks like a
        // rendering bug and is not one.
        try engine.solve(target: "both")

        await renderNow()
    }

    // MARK: - parameters

    /// A parameter changed. Mark the render stale and schedule one.
    func parameterChanged(_ key: String, _ value: Double) {
        params[key] = value
        paramsDirty = true
        scheduleRender()
    }

    /// The film changed: reopen, because the stock is a session-level choice.
    func filmChanged(_ stock: String) {
        filmStock = stock
        // Offer the paper that goes with this film, if the engine has a
        // preview table paired with it.
        if let paired = StockCatalog.pairedPaper(forFilm: stock, in: engine?.resources ?? SpektraEngine.defaultResources()) {
            printStock = paired
        }
        reopenAndRender()
    }

    /// The paper changed: reopen, for the same reason.
    func paperChanged(_ stock: String) {
        printStock = stock
        reopenAndRender()
    }

    /// Reopen the session with the current stocks and parameters.
    private func reopenAndRender() {
        guard let frame, let engine else { return }
        var delta = ParamDefaults.delta(film: filmStock, paper: printStock)
        for (key, value) in params { delta[key] = .number(value) }
        do {
            // The pointer has to outlive the call: the engine borrows the
            // pixels for the duration of `open` and copies what it keeps.
            try frame.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                _ = try engine.open(pixels: EnginePixels(
                    data: base,
                    width: frame.width,
                    height: frame.height), params: delta)
            }
            try engine.solve(target: "both")
            paramsDirty = false
            scheduleRender()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - the render loop

    /// Ask for a render. It runs when the current one is done and the user
    /// has stopped moving.
    func scheduleRender() {
        needsRender = true
        guard !renderInFlight else { return }
        // `@MainActor` on the closure: `Task { ... }` is `@Sendable` by
        // default, and a closure that captures a `MainActor`-isolated
        // `ViewModel` is not Sendable unless the closure says where it
        // runs. Without this, Swift 6's strict concurrency rejects it.
        renderTask = Task { @MainActor [weak self] in
            // A short settle, so a drag does not render on every frame. The
            // preview is a reprint of a cached negative — fast — but not free.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderNow()
        }
    }

    /// Render now, one at a time.
    private func renderNow() async {
        guard renderInFlight == false else { return }
        guard let engine, let renderer else { return }
        guard frame != nil else { return }

        renderInFlight = true
        defer {
            renderInFlight = false
            // A request that arrived while this render was running runs now.
            if needsRender {
                needsRender = false
                scheduleRender()
            }
        }

        state = .rendering

        do {
            if paramsDirty {
                var delta: [String: ParamValue] = [:]
                for (key, value) in params { delta[key] = .number(value) }
                _ = try engine.setParams(delta)
                paramsDirty = false
                // The exposure has to be recomputed when the compensation
                // changed, or the print keeps the old EV.
                try engine.solve(target: "both")
            }

            // `live` is the interactive tier: the engine renders at the live
            // long edge (2048 px), which is what a phone screen can show.
            let result = try engine.render(tier: "live", reprint: true)
            renderer.setTexture(result.texture)
            renderedTexture = result.texture
            renderIdentity = result.progressID.isEmpty
                ? UUID().uuidString
                : result.progressID
            lastRenderMs = result.elapsedMs
            state = .ready
            statusText = String(format: "渲染完成 · %.0f ms · %d×%d",
                                result.elapsedMs, result.width, result.height)
        } catch {
            // The state stays `.failed`. It used to be forced back to `.ready`
            // right here, which is the worst possible outcome: no error shown,
            // `renderedTexture` nil, and every slider disabled with no
            // explanation.
            state = .failed(error.localizedDescription)
            statusText = "渲染失败：\(error.localizedDescription)"
        }
    }

    // MARK: - exporting

    /// Export the print to the photo library.
    ///
    /// The export is a `full` tier render — the original resolution — decoded
    /// from the original file rather than the preview, so the exported file
    /// is as large as the photo was.
    func exportToPhotos() async {
        guard let engine else {
            statusText = "引擎没有启动"
            return
        }
        guard let data = pickedData else {
            statusText = "还没有可导出的照片"
            return
        }
        state = .importing
        statusText = "正在导出原始分辨率…"

        do {
            // Re-decode at full size, from the same bytes that imported
            // successfully — never re-request them from the picker, whose
            // `loadTransferable` may return a different representation.
            let full = try ImageDecoder.decode(data: data, maxLongEdge: nil)

            // Reopen on the full frame, with the same stocks and parameters.
            var delta = ParamDefaults.delta(film: filmStock, paper: printStock)
            for (key, value) in params { delta[key] = .number(value) }
            // The pointer has to outlive the call: the engine borrows the
            // pixels for the duration of `open` and copies what it keeps.
            try full.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                _ = try engine.open(pixels: EnginePixels(
                    data: base,
                    width: full.width,
                    height: full.height), params: delta)
            }
            try engine.solve(target: "both")

            let result = try engine.render(tier: "full", reprint: false)
            guard let texture = result.texture else {
                throw EngineError.failed(status: -1, message: "引擎没有返回图像")
            }

            let image = try await Self.makeImage(from: texture, rowStridePx: result.rowStridePx)
            try await PhotoLibrary.save(image)

            statusText = String(format: "已导出 %d×%d 到相册", result.width, result.height)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "导出失败：\(error.localizedDescription)"
        }
    }

    /// The engine's texture → a `UIImage`, in sRGB.
    ///
    /// The texture is gamma-encoded ProPhoto RGB, `RGBA16Unorm` (the engine
    /// applies `output_cctf_encoding` with `cctf_mode_for("ProPhoto RGB") == 1`);
    /// the file has to be sRGB, so the conversion happens here:
    /// ProPhoto → linear sRGB → sRGB-encoded 8-bit.
    ///
    /// The row offset is `y * rowStridePx * 4` **uint16s** in the *engine's*
    /// own linear memory — but a private texture has no CPU-visible memory, so
    /// we never read it directly. Instead we blit into a shared buffer: the
    /// blit packs `width` pixels per row, so the buffer is addressed by
    /// `y * width + x` (the engine's `rowStridePx` pitch is irrelevant here).
    @MainActor
    private static func makeImage(from texture: MTLTexture, rowStridePx: Int) async throws -> UIImage {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4 * MemoryLayout<UInt16>.size   // RGBA16 = 8 bytes
        let bytesPerRow = width * bytesPerPixel

        // 1) Read the private texture back to the CPU. A private-storage
        //    texture cannot be read with `contents()`/`getBytes` — the only
        //    supported path is a blit into a shared `MTLBuffer`.
        //    REQUIRES the engine to have created the texture with
        //    `MTLTextureUsageCopySource`; otherwise this fails at runtime.
        guard let buffer = texture.device.makeBuffer(length: bytesPerRow * height,
                                                     options: .storageModeShared) else {
            throw EngineError.failed(status: -1, message: "无法分配回读缓冲")
        }
        guard let commandBuffer = texture.device.makeCommandQueue()?.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw EngineError.failed(status: -1, message: "无法创建 blit 编码器")
        }
        blit.copy(from: texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: 0)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 2) Per-pixel RGBA16 uint16 data, now on the CPU (tightly packed).
        //    `contents()` on a shared buffer is non-optional, so there is
        //    nothing to unwrap.
        let src = buffer.contents().assumingMemoryBound(to: UInt16.self)

        // 3) RGBA16Unorm → Float → linear ProPhoto → linear sRGB → sRGB 8-bit.
        //    The engine renders in the ProPhoto working space but applies the
        //    output CCTF on write (`io.output_cctf_encoding = true`,
        //    `cctf_mode_for("ProPhoto RGB") == 1`), so the stored values are
        //    **gamma-encoded** ProPhoto, not linear. Recover linear ProPhoto
        //    first, with the inverse of *ProPhoto's* curve -- a gamma of 1.8
        //    with a 16x linear toe, which is what `nodes.metal`'s mode 1 is.
        //    Skipping this step double-encodes and crushes the image to
        //    near-black; using sRGB's curve instead of ProPhoto's shifts the
        //    midtones, which is quieter but just as wrong.
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let m = ImageDecoder.proPhotoToSRGBLinear
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                for x in 0..<width {
                    let si = (y * width + x) * 4
                    let di = si
                    let encR = Float(src[si + 0]) / 65535.0
                    let encG = Float(src[si + 1]) / 65535.0
                    let encB = Float(src[si + 2]) / 65535.0
                    let r = ImageDecoder.proPhotoToLinear(encR)
                    let g = ImageDecoder.proPhotoToLinear(encG)
                    let b = ImageDecoder.proPhotoToLinear(encB)
                    let lr = m[0] * r + m[1] * g + m[2] * b
                    let lg = m[3] * r + m[4] * g + m[5] * b
                    let lb = m[6] * r + m[7] * g + m[8] * b
                    dst[di + 0] = ImageDecoder.linearToSrgb(lr)
                    dst[di + 1] = ImageDecoder.linearToSrgb(lg)
                    dst[di + 2] = ImageDecoder.linearToSrgb(lb)
                    dst[di + 3] = 255
                }
            }
        }

        // 4) An 8-bit sRGB CGImage (already transfer-encoded; colour space sRGB).
        let data = Data(bytes: out, count: out.count)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw EngineError.failed(status: -1, message: "无法构造数据提供器")
        }
        guard let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            throw EngineError.failed(status: -1, message: "无法构造图像")
        }
        return UIImage(cgImage: cgImage)
    }

}

/// RAW 原始文件字节（ARW/CR3/DNG…）。优先按 `rawImage` 取原始数据；普通照片
/// 回退到 `image`。`PhotosPickerItem.loadTransferable(type: Data.self)` 对于
/// RAW 只能拿到渲染后的位图，拿不到原始字节，所以这里用自定义 Transferable。
///
/// The `importedContentType:` label is the one this SDK expects; the older
/// `importedAs:` is not a parameter of `DataRepresentation` any more, and
/// writing it is a compile error rather than a deprecation.
struct PickedImageData: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .rawImage) { Self(data: $0) }
        DataRepresentation(importedContentType: .image) { Self(data: $0) }
    }
}

/// Saving to the photo library, with the permission the app needs.
enum PhotoLibrary {
    /// Ask for permission and save.
    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.permissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}

enum ExportError: Error, CustomStringConvertible, LocalizedError {
    case permissionDenied
    var description: String {
        switch self {
        case .permissionDenied: "没有相册写入权限，请在系统设置里允许"
        }
    }
    var errorDescription: String? { description }
}
