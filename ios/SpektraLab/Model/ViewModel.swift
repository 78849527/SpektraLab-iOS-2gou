//  ViewModel.swift — one photo, one look, one preview.
//
//  Rewritten from the ground up. The old model drove a C++ session: it
//  downloaded a 15 MB resource archive on first launch, decoded into linear
//  ProPhoto float32, called `spk_open`, solved the exposure, rendered a Metal
//  texture, and blitted it back for export. Any one of those steps could put
//  an error on screen at import time, and the ones that threw across the C
//  boundary took the process down instead.
//
//  The new model has no engine at all. ImageIO decodes the picked photo at a
//  bounded size, Core Image grades it, and CIContext makes a UIImage. There
//  is no network, no profile file, no C++ exception, no texture, and no
//  colour-space round trip. A photo either decodes or it says plainly why.
//
//  Three frames are kept, all lazy `CIImage`s:
//
//    * `sourceImage`   — up to 3000 px, for export;
//    * `previewSource` — up to 1440 px, for the live preview;
//    * `thumbSource`   — a 168 px centre crop, for the filter strip.
//
//  Everything runs on the main actor. `CIImage` is not `Sendable`, and a
//  preview that fits on a phone screen does not need a background queue.

import Foundation
import SwiftUI
import Photos
import PhotosUI
import UIKit
import CoreImage
import ImageIO

@MainActor
final class ViewModel: ObservableObject {

    enum AppState: Equatable {
        case empty
        case importing
        case rendering
        case ready
        case failed(String)
    }

    // MARK: - what the screen shows

    @Published private(set) var state: AppState = .empty
    @Published private(set) var statusText = "导入一张照片，滑动挑选滤镜"
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var originalImage: UIImage?
    @Published private(set) var thumbs: [String: UIImage] = [:]
    @Published private(set) var sourceDescription = ""
    @Published private(set) var lastRenderMs: Double = 0

    @Published var selectedFilterID: String = FilmLook.defaultID
    @Published var intensity: Double = 1.0

    /// The strip's contents. A value, not a fetched resource.
    let filters = FilmLook.catalog

    // MARK: - the frames

    private var sourceImage: CIImage?
    private var previewSource: CIImage?
    private var thumbSource: CIImage?
    private var pickedItem: PhotosPickerItem?

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var renderTask: Task<Void, Never>?

    // MARK: - importing

    /// Take a photo from the library.
    ///
    /// `Data` is the one transfer representation every picker item supports —
    /// no custom `Transferable`, no RAW-specific branch that only some UTI
    /// paths reach. ImageIO then decodes it with a hard long-edge cap, which
    /// is what keeps a 48 MP camera file from becoming an OOM kill.
    func importPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        renderTask?.cancel()
        state = .importing
        statusText = "正在读取照片…"

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  !data.isEmpty else {
                throw LookError.unreadable
            }
            let (full, size) = try makeSource(from: data, longEdge: 3000)
            guard size.width > 0, size.height > 0 else { throw LookError.unreadable }

            sourceImage = full
            pickedItem = item
            sourceDescription = "\(Int(size.width)) × \(Int(size.height))"

            let ps = min(1, 1440 / max(full.extent.width, full.extent.height))
            let preview = normalised(full.transformed(
                by: CGAffineTransform(scaleX: ps, y: ps)))
            previewSource = preview
            thumbSource = squareCrop(preview, side: 168)
            originalImage = makeUIImage(from: preview)

            await buildThumbnails()
            renderPreviewNow()
        } catch {
            // A failed import must not wipe the picture that was already on
            // screen. It says what happened in a dismissible notice instead.
            state = .failed("导入失败：\(error.localizedDescription)")
            statusText = "导入失败"
        }
    }

    /// Decode at a bounded size, with a fallback for containers ImageIO's
    /// thumbnail path refuses.
    private func makeSource(from data: Data, longEdge: Int) throws -> (CIImage, CGSize) {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: longEdge,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (CIImage(cgImage: cg), CGSize(width: cg.width, height: cg.height))
            }
            if let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let image = CIImage(cgImage: cg)
                let scale = min(1, CGFloat(longEdge) / max(image.extent.width, image.extent.height))
                let scaled = normalised(image.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)))
                return (scaled, CGSize(width: scaled.extent.width, height: scaled.extent.height))
            }
        }
        // Last resort for a format ImageIO would not open but UIKit will.
        if let ui = UIImage(data: data), let cg = ui.cgImage {
            let image = CIImage(cgImage: cg)
            let scale = min(1, CGFloat(longEdge) / max(image.extent.width, image.extent.height))
            let scaled = normalised(image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)))
            return (scaled, CGSize(width: scaled.extent.width, height: scaled.extent.height))
        }
        throw LookError.unreadable
    }

    /// Give a `CIImage` a zero origin, so `createCGImage(from: extent)` is
    /// unambiguous about which pixels it should produce.
    private func normalised(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard abs(extent.origin.x) > 0.01 || abs(extent.origin.y) > 0.01 else { return image }
        return image.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x, y: -extent.origin.y))
    }

    /// A centre square at a fixed size, for the strip.
    private func squareCrop(_ image: CIImage, side: CGFloat) -> CIImage {
        let extent = image.extent
        let shortest = min(extent.width, extent.height)
        guard shortest > 0 else { return image }
        let rect = CGRect(x: extent.midX - shortest / 2,
                          y: extent.midY - shortest / 2,
                          width: shortest, height: shortest)
        let cropped = image.cropped(to: rect)
        let scale = side / shortest
        return normalised(cropped.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)))
    }

    // MARK: - the strip

    /// One thumbnail per look, made from the user's own photo. Yielding
    /// between them keeps the first frame of the import from stalling.
    private func buildThumbnails() async {
        guard let base = thumbSource else { return }
        var built: [String: UIImage] = [:]
        built.reserveCapacity(filters.count)
        for look in filters {
            let graded = FilmRenderer.render(look, on: base, intensity: 1)
            if let ui = makeUIImage(from: graded) { built[look.id] = ui }
            await Task.yield()
        }
        thumbs = built
    }

    // MARK: - choosing a look

    func selectFilter(_ id: String) {
        guard selectedFilterID != id else { return }
        selectedFilterID = id
        schedulePreview()
    }

    func intensityChanged(_ value: Double) {
        intensity = value
        schedulePreview()
    }

    /// A drag must not render sixty times. A short settle coalesces it into
    /// one frame, and a newer request replaces the pending one.
    private func schedulePreview() {
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard !Task.isCancelled else { return }
            self?.renderPreviewNow()
        }
    }

    private func renderPreviewNow() {
        guard let base = previewSource else { return }
        let look = FilmLook.look(withID: selectedFilterID)
        let started = CFAbsoluteTimeGetCurrent()
        let graded = FilmRenderer.render(look, on: base, intensity: intensity)
        guard let ui = makeUIImage(from: graded) else {
            state = .failed("预览渲染失败，请换一张照片试试")
            statusText = "预览失败"
            return
        }
        previewImage = ui
        lastRenderMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        state = .ready
        statusText = "\(look.name) · \(look.tag) · 强度 \(Int(intensity * 100))%"
    }

    /// Dismiss an error notice without changing the picture.
    func dismissFailure() {
        if case .failed = state {
            state = previewImage == nil ? .empty : .ready
        }
    }

    private func makeUIImage(from image: CIImage) -> UIImage? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: - exporting

    /// Re-grade the full-size frame and save it. There is no second decode
    /// and no re-open: the same `CIImage` is rendered at its own extent.
    func exportToPhotos() async {
        guard let source = sourceImage else {
            statusText = "请先导入一张照片"
            return
        }
        state = .rendering
        statusText = "正在以原图尺寸导出…"

        let look = FilmLook.look(withID: selectedFilterID)
        let graded = FilmRenderer.render(look, on: source, intensity: intensity)
        guard let cg = context.createCGImage(graded, from: source.extent) else {
            state = .failed("导出失败：无法生成图像")
            return
        }
        let image = UIImage(cgImage: cg, scale: 1, orientation: .up)
        guard let jpeg = image.jpegData(compressionQuality: 0.95) else {
            state = .failed("导出失败：无法编码图像")
            return
        }

        do {
            try await Self.saveToLibrary(jpeg)
            state = .ready
            statusText = "已保存到相册 · \(Int(source.extent.width))×\(Int(source.extent.height))"
        } catch {
            state = .failed("导出失败：\(error.localizedDescription)")
        }
    }

    /// The write is done outside the main actor's isolation domain.
    ///
    /// Swift 6 will not send a `() -> Void` closure formed inside a
    /// `@MainActor` context into Photos' `performChanges`: a closure that
    /// captures an actor-isolated `UIImage` is not `Sendable`, and the
    /// diagnostic is "sending value of non-Sendable type '() -> Void' risks
    /// causing data races". Encoding to `Data` makes the captured value
    /// `Sendable`, and building the closure in a `nonisolated` function means
    /// there is no actor boundary to send it across in the first place.
    private nonisolated static func saveToLibrary(_ data: Data) async throws {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            throw LookError.permission
        }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}

/// Errors that a person can act on. Every one is a sentence, not a code.
enum LookError: LocalizedError, Sendable {
    case unreadable
    case permission
    case noImage

    var errorDescription: String? {
        switch self {
        case .unreadable: "系统没能读出这张照片，请换一张再试"
        case .permission: "没有相册写入权限，请在系统设置里允许"
        case .noImage: "还没有导入照片"
        }
    }
}
