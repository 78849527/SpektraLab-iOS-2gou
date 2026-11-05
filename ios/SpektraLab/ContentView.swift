//  ContentView.swift — the engine's picture, chosen from a scrolling strip.
//
//  This is the real SpektraLab pipeline: the frame goes to `spk_open`, the
//  enlarger is solved, and the print is rendered by the C++/Metal engine into
//  a texture that MetalCanvas draws with the engine's output transform.
//  Every film and paper here is a measured profile from
//  `<resources>/profiles`, and every slider is an engine parameter.
//
//  What changed is only how those choices are reached. The two list sheets
//  are gone; films, papers and the parameter controls now live in a bottom
//  deck with a horizontal strip, so the picture stays on screen while a
//  person swipes through them.

import SwiftUI
import PhotosUI
import MetalKit
import UIKit
import UniformTypeIdentifiers

private extension Color {
    static var labInk: Color { Color(red: 0.055, green: 0.055, blue: 0.063) }
    static var labPanel: Color { Color(red: 0.098, green: 0.098, blue: 0.110) }
    static var labCream: Color { Color(red: 0.965, green: 0.949, blue: 0.918) }
    static var labRed: Color { Color(red: 0.96, green: 0.27, blue: 0.24) }
}

struct ContentView: View {
    @EnvironmentObject private var model: ViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingExport = false
    @State private var showingFileImporter = false
    @State private var showingDiagnostics = false
    @State private var hiddenError: String?
    @State private var deck: Deck = .film
    @State private var zoom: CGFloat = 1
    @State private var savedZoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var savedPan = CGSize.zero

    private enum Deck: String, CaseIterable, Identifiable, Equatable {
        case film = "胶片"
        case paper = "相纸"
        case adjust = "调整"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.labInk.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                picture
                deckPanel
            }

            if let why = failureMessage {
                notice(why)
            }
        }
        .preferredColorScheme(.dark)
        .alert("导出照片", isPresented: $showingExport) {
            Button("保存到相册") {
                _ = Task<Void, Never> { @MainActor in
                    await model.exportToPhotos()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("以手机安全尺寸重新渲染为 JPEG 并保存到相册。")
        }
        .sheet(isPresented: $showingDiagnostics) { diagnosticsSheet }
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { @MainActor in
                await model.importFile(from: url)
            }
        }
    }

    // MARK: - top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: pickerBinding, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular, in: Circle())
            }
            .contextMenu {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("从文件导入 RAW / JPEG", systemImage: "folder")
                }
            }
            Spacer()
            Text("SpektraLab")
                .font(.system(size: 15, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Color.labCream)
            Spacer()
            Button {
                showingExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular, in: Circle())
            }
            .disabled(model.renderedTexture == nil)
            .opacity(model.renderedTexture == nil ? 0.4 : 1)
        }
        .tint(Color.labRed)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 6)
        .padding(.horizontal, 10)
    }

    // MARK: - the picture

    private var picture: some View {
        ZStack {
            if model.renderedTexture != nil {
                MetalCanvas(renderer: model.renderer,
                            texture: model.renderedTexture,
                            zoom: zoom,
                            pan: pan)
                    // MTLTexture is not Hashable; the engine's progress id is
                    // what tells SwiftUI the picture changed.
                    .id(model.renderIdentity)
                    .simultaneousGesture(imageGestures)
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            zoom = 1
                            savedZoom = 1
                            pan = .zero
                            savedPan = .zero
                        }
                    }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var imageGestures: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    zoom = min(max(savedZoom * value, 1), 4)
                    if zoom <= 1 { pan = .zero }
                }
                .onEnded { _ in
                    savedZoom = zoom
                    if zoom <= 1 { savedPan = .zero }
                },
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard zoom > 1 else { return }
                    pan = CGSize(width: savedPan.width + value.translation.width,
                                 height: savedPan.height + value.translation.height)
                }
                .onEnded { _ in savedPan = pan }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.labRed.opacity(0.14)).frame(width: 96, height: 96)
                Circle().stroke(Color.labRed.opacity(0.35), lineWidth: 1).frame(width: 96, height: 96)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.labRed)
            }
            VStack(spacing: 8) {
                Text("让照片拥有胶片质感")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                Text("导入照片，滑动挑选胶片与相纸\n光谱模拟 · 染料层耦合 · 颗粒与光晕")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            PhotosPicker(selection: pickerBinding, matching: .images) {
                Label("选择照片", systemImage: "photo.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .frame(minHeight: 46)
                    .background(Color.labRed, in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .padding(.top, 4)
            Button {
                showingFileImporter = true
            } label: {
                Label("从文件导入 Sony ARW / RAW", systemImage: "folder.badge.plus")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.labRed)
            }
            Text("\(model.films.count) PROFILES  ·  \(model.papers.count) PAPERS")
                .font(.caption2.weight(.medium))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [Color.labRed.opacity(0.09), Color.clear],
                           center: .center, startRadius: 10, endRadius: 240)
        )
    }

    // MARK: - the bottom deck

    private var deckPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Deck.allCases) { tab in
                    Button {
                        deck = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(deck == tab ? .semibold : .regular))
                            .foregroundStyle(deck == tab ? Color.labCream : Color.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .glassEffect(deck == tab ? .regular : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(deck == .film ? "\(model.films.count) 款胶片"
                     : deck == .paper ? "\(model.papers.count) 款相纸" : "引擎参数")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            deckContent
                .frame(height: deck == .adjust ? 176 : 116)

            statusBar
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var deckContent: some View {
        switch deck {
        case .film:
            stockStrip(model.films, selected: model.filmStock) { model.filmChanged($0) }
        case .paper:
            stockStrip(model.papers, selected: model.printStock) { model.paperChanged($0) }
        case .adjust:
            adjustPanel
        }
    }

    private func stockStrip(_ stocks: [Stock], selected: String,
                            pick: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(stocks) { stock in
                    StockTile(stock: stock,
                              selected: stock.id == selected) {
                        pick(stock.id)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
        }
    }

    private var adjustPanel: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(ParamCatalog.all) { control in
                    ParamSlider(control: control,
                                value: Binding(
                                    get: { model.params[control.key] ?? control.defaultValue },
                                    set: { model.parameterChanged(control.key, $0) }))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.state == .rendering || model.state == .importing {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(model.renderedTexture == nil
                          ? Color.secondary.opacity(0.5) : Color.labRed)
                    .frame(width: 6, height: 6)
            }
            Text(model.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                showingDiagnostics = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            if model.lastRenderMs > 0 {
                Text(String(format: "%.0f ms", model.lastRenderMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.03))
    }

    // MARK: - helpers

    private var pickerBinding: Binding<PhotosPickerItem?> {
        Binding<PhotosPickerItem?>(
            get: { pickerItem },
            set: { newItem in
                pickerItem = newItem
                hiddenError = nil
                if let newItem {
                    Task<Void, Never>(priority: .userInitiated) { @MainActor in
                        await model.importPicked(newItem)
                    }
                }
            }
        )
    }

    private var failureMessage: String? {
        guard case .failed(let why) = model.state, why != hiddenError else { return nil }
        return why
    }

    private func notice(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.labRed)
                Text(why)
                    .font(.footnote)
                    .foregroundStyle(Color.labCream)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    hiddenError = why
                    model.dismissFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            Button {
                showingDiagnostics = true
            } label: {
                Text("查看诊断信息")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.labRed)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.labRed.opacity(0.45), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, deck == .adjust ? 262 : 202)
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("把这段内容发给开发者，可以直接定位引擎侧的问题。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(model.diagnostics)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("复制") {
                        UIPasteboard.general.string = model.diagnostics
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - the engine's canvas

/// The engine's texture, drawn. `MTKView` is paused with an explicit
/// `draw()`: the app draws when a render lands, not sixty times a second.
struct MetalCanvas: UIViewRepresentable {
    let renderer: CanvasRenderer?
    let texture: MTLTexture?
    let zoom: CGFloat
    let pan: CGSize

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer?.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer?.setTexture(texture)
        renderer?.setViewport(zoom: zoom,
                              pan: CGPoint(x: pan.width, y: pan.height),
                              size: view.bounds.size)
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        weak var renderer: CanvasRenderer?

        init(renderer: CanvasRenderer?) {
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}

// MARK: - a slider

struct ParamSlider: View {
    let control: ParamControl
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(control.title).font(.footnote)
                Spacer()
                Text(formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: control.range)
                .tint(Color.labRed)
        }
    }

    private var formatted: String {
        if control.range.lowerBound < 0 {
            return String(format: "%+.2f", value)
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - one tile in the strip

/// A measured profile, shown on the user's own photo. The tint is only a
/// navigation cue: the picture itself is always rendered by the engine.
struct StockTile: View {
    let stock: Stock
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: [swatch.opacity(0.88), swatch.opacity(0.34)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: stock.support == .film ? "film.stack" : "photo.stack")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.88))
                    Text(shortCode)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                }
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Color.labRed : Color.white.opacity(0.10),
                                lineWidth: selected ? 2.5 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.labRed)
                            .background(Color.labCream, in: Circle())
                            .padding(3)
                    }
                }

                Text(stock.name)
                    .font(.caption2.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.labRed : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 74)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: selected)
    }

    /// A stable colour per profile, so the strip reads as a set of looks
    /// rather than a list of identical thumbnails.
    private var swatch: Color {
        var hash = 0
        for scalar in stock.id.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        let hue = Double(hash % 360) / 360.0
        let paper = stock.support.rawValue == "paper"
        let slide = stock.type.rawValue == "positive"
        return Color(hue: hue,
                     saturation: paper ? 0.16 : (slide ? 0.55 : 0.38),
                     brightness: 0.88)
    }

    /// The upstream profiles contain measurements and metadata, but no image
    /// thumbnails. Use a small generated badge so every stock has a stable,
    /// recognisable tile instead of reusing the imported photo or showing a
    /// blank colour square.
    private var shortCode: String {
        stock.id.split(separator: "_")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }
            .joined()
    }
}
