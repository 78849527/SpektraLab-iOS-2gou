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
import ImageIO

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

    /// The film's physical edge. These are engine parameters, not a drawn
    /// border: the rebate, holes and edge print are developed on the negative.
    @Published private(set) var filmBorderEnabled = false
    @Published private(set) var overscanFormat = FilmGateCatalog.automaticID
    @Published private(set) var stripOrientation: FilmStripOrientation = .automatic

    /// The camera's date back, printed through the film base.
    @Published private(set) var dateBackEnabled = false
    @Published private(set) var dateBackStyle: DateBackStyle = .lcd
    @Published private(set) var dateBackPlacement: DateBackPlacement = .frame
    @Published private(set) var dateBackCorner: DateBackCorner = .br
    @Published private(set) var dateStampDate = Date()
    @Published private(set) var shootingDataText = "1/125  F2.8  ISO 400  50mm"

    /// The catalogue, read at launch.
    @Published private(set) var catalog = StockCatalog(films: [], papers: [], slides: [])

    /// The stocks, in the order the scrolling strip shows them.
    var films: [Stock] { catalog.films + catalog.slides }
    var papers: [Stock] { catalog.papers }

    var currentFilmName: String {
        films.first { $0.id == filmStock }?.name ?? filmStock
    }

    var currentPaperName: String {
        papers.first { $0.id == printStock }?.name ?? printStock
    }

    var selectedGate: FilmGate {
        FilmGateCatalog.resolve(selection: overscanFormat, imageAspect: naturalAspect)
    }

    /// The crop shape handed to the engine. The engine reads the strip's
    /// direction from this shape, so changing it here changes the real
    /// perforations and rebate, not just the SwiftUI frame.
    var filmCropAspect: CGFloat {
        stripOrientation.targetAspect(for: selectedGate, sourceAspect: naturalAspect)
    }

    var gateDisplayName: String {
        overscanFormat == FilmGateCatalog.automaticID
            ? "自动 · \(selectedGate.title)"
            : selectedGate.title
    }

    var filmEdgeDisplayName: String {
        guard filmBorderEnabled else { return "关闭" }
        return stripOrientation == .automatic
            ? gateDisplayName
            : "\(gateDisplayName) · \(stripOrientation.title)"
    }

    var stripOrientationAvailable: Bool { !selectedGate.isSquare }

    var dateBackAvailable: Bool { selectedGate.supportsDateBack }

    var dateStampText: String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: dateStampDate)
        return String(format: "'%02d %02d %02d",
                      (parts.year ?? 2000) % 100,
                      parts.month ?? 1,
                      parts.day ?? 1)
    }

    /// A rebate date needs the film edge around the gate. Without it the
    /// engine prints the date in the picture instead.
    var effectiveDateBackPlacement: DateBackPlacement {
        filmBorderEnabled ? dateBackPlacement : .frame
    }

    /// Enough state to diagnose an engine failure without a debugger.
    var diagnostics: String {
        let root = engine?.resources.path ?? SpektraEngine.defaultResources().path
        return [
            "state: \(state)",
            "profiles: \(catalog.films.count) films / \(catalog.slides.count) slides / \(catalog.papers.count) papers",
            "resources: \(root)",
            "engine: \(engine == nil ? "not started" : "ready")",
            "film edge: \(filmBorderEnabled ? "on" : "off") · \(gateDisplayName) · \(stripOrientation.detail) · crop \(String(format: "%.4f", filmCropAspect))",
            "status: \(statusText)"
        ].joined(separator: "\n")
    }

    /// The picked photo, kept so it can be re-decoded at full size for export.
    private var pickedItem: PhotosPickerItem?
    private var originalTypeHint: UTType?
    /// Original bytes for the full-resolution export; a preview-only
    /// transferable must never replace them.
    private var originalData: Data?

    /// The decoded frame in the engine's input space.
    private var frame: DecodedFrame?
    /// The photograph's own long/short ratio, before a film gate crops it.
    private var naturalAspect: CGFloat = 3.0 / 2.0
    /// Gate and orientation changes re-decode the photograph. Coalesce them so
    /// a slow, older decode can never finish last and restore the previous
    /// direction after the user has picked a new one.
    private var effectReloadNeeded = false
    private var effectReloadRunning = false
    private var sourceGeneration = 0

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

    /// Load original bytes, preferring a RAW representation when the picker
    /// exposes one. Plain `Data.self` is re-encoded by Photos for RAW assets.
    private static func loadData(from item: PhotosPickerItem) async throws -> Data {
        if let raw = try? await item.loadTransferable(type: PickedImageData.self)?.data,
           !raw.isEmpty {
            return raw
        }
        return try await item.loadTransferable(type: Data.self) ?? Data()
    }

    /// Take a photo from the library.
    func importPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        pickedItem = item
        state = .importing
        statusText = "正在读取照片…"

        do {
            let data = try await Self.loadData(from: item)
            guard !data.isEmpty else {
                throw DecodeError.unreadable("照片没有返回数据")
            }
            // `PickedImageData` returns the original bytes but not the type
            // that produced them. Keep the picker's RAW UTI, or sniff the
            // container, so an ARW is not mistaken for a plain public.tiff.
            let typeHint = item.supportedContentTypes.first {
                $0.conforms(to: .rawImage)
            } ?? ImageDecoder.inferredRAWTypeHint(for: data)
            try await importData(data, typeHint: typeHint)
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "导入失败"
        }
    }

    /// Import a file selected from Files. This path is essential for Sony
    /// ARW: PhotosPicker may expose only a rendered preview for some RAW
    /// assets, while a security-scoped file URL gives Core Image the original
    /// container and its maker metadata.
    func importFile(from url: URL) async {
        state = .importing
        statusText = "正在读取原始文件…"
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else { throw DecodeError.unreadable("文件为空") }
            try await importData(data, typeHint: UTType(filenameExtension: url.pathExtension))
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "导入失败：\(url.lastPathComponent)"
        }
    }

    private func importData(_ data: Data, typeHint: UTType? = nil) async throws {
        sourceGeneration &+= 1
        effectReloadNeeded = false
        originalData = data
        originalTypeHint = typeHint
        // The preview decode is small: the live tier renders at 2048 px on
        // the long edge, so a bigger decode buys nothing and costs memory.
        let decoded = try ImageDecoder.decode(data: data,
                                              maxLongEdge: ImageDecoder.previewLongEdge,
                                              typeHint: typeHint)
        naturalAspect = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
        let framed = filmBorderEnabled
            ? decoded.centerCropped(toTargetAspect: filmCropAspect)
            : decoded
        try await loadFrame(framed)
        statusText = "已载入 \(decoded.width)×\(decoded.height) · \(String(format: "%.1f", decoded.megapixels)) MP"
    }

    /// Every path that opens a session uses the same complete delta. The
    /// stocks are not enough: the film edge and date back are exposure on the
    /// negative, so leaving them out here would make the preview and export
    /// disagree with the controls.
    private func currentEngineDelta() -> [String: ParamValue] {
        var delta = ParamDefaults.delta(film: filmStock, paper: printStock)
        for (key, value) in params { delta[key] = .number(value) }

        let gate = selectedGate
        delta["overscan_active"] = .bool(filmBorderEnabled)
        delta["overscan_format"] = .string(gate.id)
        delta["overscan_mode"] = .string("strip")
        delta["overscan_gate"] = .string("auto")
        delta["overscan_holes"] = .string("white")
        delta["overscan_carrier"] = .string("none")
        delta["overscan_edge_text"] = .string(currentFilmName.uppercased())
        delta["overscan_frame_number"] = .number(12)
        delta["overscan_camera_seed"] = .number(7)
        delta["overscan_frame_seed"] = .number(11)
        delta["overscan_fog"] = .number(1)
        delta["overscan_leaks"] = .number(0)

        let dateActive = dateBackEnabled && gate.supportsDateBack
        delta["date_imprint_active"] = .bool(dateActive)
        delta["date_imprint_text"] = .string(dateStampText)
        delta["date_imprint_data_text"] = .string(shootingDataText)
        delta["date_imprint_placement"] = .string(effectiveDateBackPlacement.rawValue)
        delta["date_imprint_style"] = .string(dateBackStyle.rawValue)
        delta["date_imprint_corner"] = .string(dateBackCorner.rawValue)
        delta["date_imprint_ev"] = .number(3.5)
        delta["date_imprint_size"] = .number(1)
        delta["date_imprint_inset_x"] = .number(3)
        delta["date_imprint_inset_y"] = .number(2.4)
        return delta
    }

    /// Load an already-decoded frame: open a session and render the first
    /// preview.
    private func loadFrame(_ decoded: DecodedFrame) async throws {
        guard let engine else { throw EngineError.failed(status: -1, message: "引擎没有启动") }
        frame = decoded
        sourceSize = CGSize(width: decoded.width, height: decoded.height)

        // Open with the current stocks and parameters, so the first preview
        // already shows what the user chose.
        let openDelta = currentEngineDelta()

        // The pointer has to stay alive across the `open` call: the engine
        // borrows the pixels for the duration of that call and copies what it
        // keeps, so the buffer must not go out of scope before it returns.
        // Taking the address inside a closure and using it outside would
        // leave it dangling -- which reads as a frame of noise rather than
        // as a crash, and is much harder to find.
        let reply = try await engine.perform {
            try decoded.pixels.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    throw EngineError.failed(status: -1, message: "解码结果为空")
                }
                return try engine.open(pixels: EnginePixels(
                    data: base,
                    width: decoded.width,
                    height: decoded.height), params: openDelta)
            }
        }

        if let meta = reply.meta, let w = meta.width, let h = meta.height {
            sourceSize = CGSize(width: w, height: h)
        }

        // The solve must happen before the first render, or the print uses
        // default exposure and the highlights blow out — which looks like a
        // rendering bug and is not one.
        try await engine.perform { try engine.solve(target: "both") }

        await renderNow()
    }

    // MARK: - parameters

    /// Dismiss an error notice without losing the picture already on screen.
    func dismissFailure() {
        if case .failed = state {
            state = renderedTexture == nil ? .empty : .ready
        }
    }

    /// A parameter changed. Mark the render stale and schedule one.
    func parameterChanged(_ key: String, _ value: Double) {
        params[key] = value
        paramsDirty = true
        scheduleRender()
    }

    /// Turn the physical film edge on or off. The picture has to be re-opened
    /// with the gate's aspect ratio: the engine refuses a crop that is not the
    /// selected format's shape, and stretching an edge around the old frame
    /// would not be the same negative.
    func setFilmBorderEnabled(_ enabled: Bool) {
        guard filmBorderEnabled != enabled else { return }
        filmBorderEnabled = enabled
        if !enabled && dateBackPlacement == .rebate {
            dateBackPlacement = .frame
        }
        reloadPreviewForFilmEffect()
    }

    /// Pick an explicit gate, or automatic matching against the photograph.
    func setOverscanFormat(_ id: String) {
        guard id == FilmGateCatalog.automaticID || FilmGateCatalog.gate(id: id) != nil else { return }
        overscanFormat = id
        if selectedGate.isSquare && stripOrientation != .automatic {
            stripOrientation = .automatic
        }
        if !selectedGate.supportsDateBack {
            dateBackEnabled = false
            dateBackPlacement = .frame
        }
        if filmBorderEnabled { reloadPreviewForFilmEffect() }
    }

    /// Choose which way the strip runs. The frame is re-cropped to the chosen
    /// orientation, so a horizontal choice on a portrait source selects a
    /// horizontal slice of the photograph and the engine builds a horizontal
    /// strip around it. It never rotates the picture or fakes the rebate.
    func setStripOrientation(_ orientation: FilmStripOrientation) {
        guard stripOrientation != orientation else { return }
        guard !selectedGate.isSquare || orientation == .automatic else { return }
        stripOrientation = orientation
        if filmBorderEnabled { reloadPreviewForFilmEffect() }
    }

    func setDateBackEnabled(_ enabled: Bool) {
        guard enabled == false || selectedGate.supportsDateBack else { return }
        dateBackEnabled = enabled
        if enabled && !filmBorderEnabled { dateBackPlacement = .frame }
        scheduleEffectRender()
    }

    func setDateBackStyle(_ style: DateBackStyle) {
        dateBackStyle = style
        scheduleEffectRender()
    }

    func setDateBackPlacement(_ placement: DateBackPlacement) {
        dateBackPlacement = (placement == .rebate && filmBorderEnabled) ? .rebate : .frame
        scheduleEffectRender()
    }

    func setDateBackCorner(_ corner: DateBackCorner) {
        dateBackCorner = corner
        scheduleEffectRender()
    }

    func setDateStampDate(_ date: Date) {
        guard date != dateStampDate else { return }
        dateStampDate = date
        scheduleEffectRender()
    }

    func setShootingDataText(_ text: String) {
        guard text != shootingDataText else { return }
        shootingDataText = text
        scheduleEffectRender()
    }

    private func scheduleEffectRender() {
        guard frame != nil else { return }
        paramsDirty = true
        scheduleRender()
    }

    /// A gate change has to reload the preview because the crop is applied
    /// before the engine sees the frame. A toggle-off reloads the full frame,
    /// restoring the part the rebate had cropped away.
    private func reloadPreviewForFilmEffect() {
        guard originalData != nil else {
            scheduleEffectRender()
            return
        }
        effectReloadNeeded = true
        guard !effectReloadRunning else { return }
        effectReloadRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.effectReloadNeeded {
                self.effectReloadNeeded = false
                self.state = .importing
                self.statusText = self.filmBorderEnabled
                    ? "正在裁切到 \(self.gateDisplayName)…"
                    : "正在恢复完整画面…"
                do {
                    guard let data = self.originalData else { break }
                    let sourceGeneration = self.sourceGeneration
                    let hint = self.originalTypeHint
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try ImageDecoder.decode(data: data,
                                                maxLongEdge: ImageDecoder.previewLongEdge,
                                                typeHint: hint)
                    }.value
                    guard sourceGeneration == self.sourceGeneration else { continue }
                    self.naturalAspect = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
                    let gate = self.selectedGate
                    if !gate.supportsDateBack {
                        self.dateBackEnabled = false
                        self.dateBackPlacement = .frame
                    }
                    let framed = self.filmBorderEnabled
                        ? decoded.centerCropped(toTargetAspect: self.filmCropAspect)
                        : decoded
                    try await self.loadFrame(framed)
                } catch {
                    self.state = .failed(error.localizedDescription)
                    self.statusText = "片边载入失败"
                }
            }
            self.effectReloadRunning = false
            if self.effectReloadNeeded { self.reloadPreviewForFilmEffect() }
        }
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
        let openDelta = currentEngineDelta()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.perform {
                    // The pointer has to outlive the call: the engine borrows
                    // the pixels for the duration of `open` and copies what
                    // it keeps.
                    try frame.pixels.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else {
                            throw EngineError.failed(status: -1, message: "解码结果为空")
                        }
                        _ = try engine.open(pixels: EnginePixels(
                            data: base,
                            width: frame.width,
                            height: frame.height), params: openDelta)
                    }
                    try engine.solve(target: "both")
                }
                self.paramsDirty = false
                self.scheduleRender()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
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

        // This render is consuming the request that is currently pending.
        // A change made while it is awaiting the engine sets the flag again.
        needsRender = false
        renderInFlight = true
        defer {
            renderInFlight = false
            // A request that arrived while this render was running runs now.
            if needsRender {
                scheduleRender()
            }
        }

        state = .rendering

        do {
            let dirty = paramsDirty
            let changed = currentEngineDelta()
            let result = try await engine.perform {
                if dirty {
                    _ = try engine.setParams(changed)
                    // The exposure has to be recomputed when the
                    // compensation changed, or the print keeps the old EV.
                    try engine.solve(target: "both")
                }

                // `live` is the interactive tier: the engine renders at the
                // live long edge (2048 px), which is what a phone screen can
                // show.
                return try engine.render(tier: "live", reprint: true)
            }
            if dirty { paramsDirty = false }
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
    /// Decode the source at its original resolution and render in strips.
    func exportToPhotos() async {
        guard let engine, let originalData else {
            statusText = "还没有可导出的照片"
            return
        }
        state = .importing
        statusText = "正在导出高质量 JPEG…"

        do {
            let data = originalData
            let hint = originalTypeHint
            let cropAspect = filmBorderEnabled ? filmCropAspect : nil
            // Decoding a RAW container is CPU-heavy. Do it off the main actor
            // so the export sheet keeps moving and the UI never freezes.
            let full = try await Task.detached(priority: .userInitiated) {
                try ImageDecoder.decode(data: data,
                                        maxLongEdge: ImageDecoder.exportLongEdge,
                                        typeHint: hint,
                                        targetAspect: cropAspect)
            }.value

            let exportDelta = currentEngineDelta()

            // Open, solve and render are one unit on the engine's serial
            // queue. `full` stays alive only until `open` copies it; the
            // exported image then owns the engine's 16-bit rows directly.
            let bitmap = try await engine.perform {
                try full.pixels.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else {
                        throw EngineError.failed(status: -1, message: "解码结果为空")
                    }
                    _ = try engine.open(pixels: EnginePixels(
                        data: base,
                        width: full.width,
                        height: full.height), params: exportDelta)
                }
                try engine.solve(target: "both")
                return try engine.renderBitmap(tier: "full", reprint: false)
            }

            // Encode on a background task as well: JPEG compression is the
            // second-long part after a 24 MP render and does not need the main
            // actor. No UIImage and no full-size JPEG Data are created.
            let cgImage = bitmap.cgImage
            let jpegURL = try await Task.detached(priority: .userInitiated) {
                try Self.writeJPEG(from: cgImage)
            }.value
            try await PhotoLibrary.saveJPEG(at: jpegURL)

            statusText = String(format: "已导出 %d×%d 到相册", bitmap.width, bitmap.height)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "导出失败"
        }
    }

    /// Write the engine's 16-bit sRGB image as a JPEG.
    ///
    /// `cgImage` already owns the engine rows through its data provider, so
    /// ImageIO can encode straight from those pixels. The previous path read
    /// the Metal texture into a CPU array and converted every pixel to RGBA8;
    /// that array, plus the 8-bit Data buffer, was roughly 500 MB at 24 MP and
    /// was the cause of the export-time jetsam kills.
    private nonisolated static func writeJPEG(from cgImage: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraLab-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1, nil) else {
            throw ExportError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.encodingFailed
        }
        return url
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
    static func saveJPEG(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.permissionDenied
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset()
                .addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

enum ExportError: Error, CustomStringConvertible {
    case permissionDenied
    case encodingFailed
    var description: String {
        switch self {
        case .permissionDenied: "没有相册写入权限，请在系统设置里允许"
        case .encodingFailed: "照片编码失败，无法导出 JPEG"
        }
    }
}
