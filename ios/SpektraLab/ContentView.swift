//  ContentView.swift — the app's one screen.
//
//  The loop is: pick a photo, choose a film and a paper, move the sliders,
//  look, export. Everything else is out of scope for the phone.
//
//  The layout is a portrait stack: the picture on top (the thing being
//  judged), the controls below it (the things being judged with). The
//  picture takes whatever height is left after the controls have taken what
//  they need, and the picture is never smaller than a third of the screen --
//  a preview you cannot see is not a preview.

import SwiftUI
import PhotosUI
import MetalKit

struct ContentView: View {
    @EnvironmentObject private var model: ViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingFilms = false
    @State private var showingPapers = false
    @State private var showingExport = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    picture
                    controls
                }

                if let failure = failureMessage {
                    failureOverlay(failure)
                }
            }
            .navigationTitle("SpektraLab")
            .navigationBarTitleDisplayMode(.inline)
            // The toolbar is on the NavigationStack's content rather than on
            // the ZStack, and it is a `ToolbarItemGroup` rather than a bare
            // `.toolbar { ... }`: SwiftUI has several `toolbar` overloads, and
            // with a plain one the compiler cannot tell which is meant and
            // says "ambiguous use of 'toolbar(content:)'".
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("导入", systemImage: "photo.on.rectangle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingExport = true
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.renderedTexture == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingFilms) {
            StockPicker(title: "选择胶片", stocks: model.catalog.films + model.catalog.slides,
                        selected: model.filmStock) { stock in
                model.filmChanged(stock)
            }
        }
        .sheet(isPresented: $showingPapers) {
            StockPicker(title: "选择相纸", stocks: model.catalog.papers,
                        selected: model.printStock) { stock in
                model.paperChanged(stock)
            }
        }
        .alert("导出", isPresented: $showingExport) {
            Button("保存到相册") {
                _ = Task { await model.exportToPhotos() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将以原始分辨率重新渲染并保存到相册。")
        }
        // Keyed on `pickerItem?.id` (`String?`, always `Equatable`) rather
        // than on `pickerItem` itself: `PhotosPickerItem` is not `Equatable`
        // in this SDK, so `onChange(of: pickerItem)` left the closure's
        // parameter type unresolved and the compiler then reported a
        // spurious "ambiguous use of 'init(priority:operation:)'". With a
        // concrete key the closure types resolve, and the `Task(priority:)`
        // form picks a single initializer.
        .onChange(of: pickerItem?.id) { _, _ in
            guard let item = pickerItem else { return }
            Task(priority: .userInitiated) {
                await model.importPicked(item)
            }
        }
    }

    // MARK: - the picture

    @ViewBuilder
    private var picture: some View {
        ZStack {
            if model.renderedTexture != nil {
                MetalCanvas(renderer: model.renderer, texture: model.renderedTexture)
                    // The identity is the engine's progress id, not the
                    // texture: `MTLTexture` is not `Hashable`, so it has no
                    // `hashValue` to key the view on.
                    .id(model.renderIdentity)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 180)
        .background(Color.black)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("选一张 RAW 照片开始")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("81 个波长穿过染料层，颗粒、光晕与成色剂耦合按画幅的微米尺度计算")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - the controls

    private var controls: some View {
        VStack(spacing: 0) {
            Divider().overlay(.white.opacity(0.12))

            // The two stocks: the two choices that define the picture.
            HStack(spacing: 10) {
                stockButton(title: "胶片",
                            value: nameOf(model.filmStock, in: model.catalog.films + model.catalog.slides),
                            systemImage: "film") {
                    showingFilms = true
                }
                stockButton(title: "相纸",
                            value: nameOf(model.printStock, in: model.catalog.papers),
                            systemImage: "square.grid.3x3.square") {
                    showingPapers = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // The sliders.
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ParamCatalog.all) { control in
                        ParamSlider(control: control,
                                    value: Binding(
                                        get: { model.params[control.key] ?? control.defaultValue },
                                        set: { model.parameterChanged(control.key, $0) }))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .frame(maxHeight: 268)

            // The status line: what happened, and how long it took.
            statusBar
        }
        .background(Color(white: 0.06))
    }

    private func stockButton(title: String, value: String, systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.state == .rendering {
                ProgressView().controlSize(.mini)
            }
            Text(model.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.lastRenderMs > 0 {
                Text(String(format: "%.0f ms", model.lastRenderMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(white: 0.03))
    }

    // MARK: - helpers

    private var failureMessage: String? {
        if case .failed(let why) = model.state { return why }
        return nil
    }

    @ViewBuilder
    private func failureOverlay(_ why: String) -> some View {
        VStack {
            Spacer()
            Text(why)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    private func nameOf(_ id: String, in stocks: [Stock]) -> String {
        stocks.first { $0.id == id }?.name ?? id
    }
}

// MARK: - the canvas

/// The engine's texture, drawn.
///
/// `MTKView` with `isPaused` and an explicit `draw()`: the app draws when a
/// render lands, not sixty times a second. A live preview that redraws
/// nothing has nothing to redraw.
struct MetalCanvas: UIViewRepresentable {
    let renderer: CanvasRenderer?
    let texture: MTLTexture?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer?.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.backgroundColor = .black
        // The image is shown as it is, letterboxed: the photo's own aspect
        // ratio is part of what a print is.
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer?.setTexture(texture)
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

/// One parameter, as a slider with a value that reads as a number.
///
/// The label carries the parameter's name and its value in the engine's own
/// units, because a film simulator's parameters are physical: "颗粒 0.35" means
/// something, "35%" means less.
struct ParamSlider: View {
    let control: ParamControl
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(control.title)
                    .font(.footnote)
                Spacer()
                Text(formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: control.range)
                .tint(.accentColor)
        }
    }

    private var formatted: String {
        if control.range.lowerBound < 0 {
            return String(format: "%+.2f", value)
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - the stock picker

/// A list of films or papers.
///
/// A sheet rather than a menu: there are 22 films and 6 papers, and a menu
/// with 22 items is unusable on a phone.
struct StockPicker: View {
    let title: String
    let stocks: [Stock]
    let selected: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(stocks) { stock in
                    Button {
                        onPick(stock.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stock.name)
                                    .foregroundStyle(.primary)
                                Text("\(stock.support.label) · \(stock.type.label)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if stock.id == selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
