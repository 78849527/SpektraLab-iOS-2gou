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
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.041, blue: 0.052),
                    Color(red: 0.012, green: 0.014, blue: 0.020)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                picture
                controls
            }

            if let failure = failureMessage {
                failureOverlay(failure)
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
                _ = Task<Void, Never> { @MainActor in
                    await model.exportToPhotos()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将以原始分辨率重新渲染并保存到相册。")
        }
    }

    // A plain HStack rather than `.toolbar { ... }`: iOS 17 has two
    // `toolbar(content:)` overloads (one taking a plain `View`, one a
    // `ToolbarContent` builder), and a bare toolbar here made the
    // compiler say "ambiguous use of 'toolbar(content:)'". An HStack
    // has no overload to be ambiguous about.
    private var topBar: some View {
        HStack(spacing: 12) {
            // Trigger the import from the binding's setter rather than
            // from `.onChange`: the two-argument `onChange(of:initial:_:)`
            // is iOS 17+, while this app targets iOS 16.0. A setter has
            // no availability constraint. `Task<Void, Never>` pins the
            // generic arguments so the initializer is unambiguous in a
            // `@Sendable` closure.
            PhotosPicker(selection: Binding<PhotosPickerItem?>(
                get: { pickerItem },
                set: { newItem in
                    pickerItem = newItem
                    if let newItem {
                        Task<Void, Never>(priority: .userInitiated) { @MainActor in
                            await model.importPicked(newItem)
                        }
                    }
                }
            ), matching: .images) {
                Label("导入", systemImage: "photo.on.rectangle")
            }
            Spacer()
            Text("SpektraLab").font(.headline.weight(.semibold))
            Spacer()
            Button {
                showingExport = true
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(model.renderedTexture == nil)
        }
        .font(.subheadline.weight(.semibold))
        .tint(Color(red: 0.94, green: 0.64, blue: 0.28))
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
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
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.94, green: 0.64, blue: 0.28).opacity(0.14))
                    .frame(width: 92, height: 92)

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: 92, height: 92)

                Image(systemName: "camera.aperture")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color(red: 0.94, green: 0.64, blue: 0.28))
            }

            VStack(spacing: 7) {
                Text("让照片拥有胶片质感")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("导入一张 RAW 或普通照片，选择胶片与相纸后即可实时预览。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 36)

            PhotosPicker(selection: Binding<PhotosPickerItem?>(
                get: { pickerItem },
                set: { newItem in
                    pickerItem = newItem
                    if let newItem {
                        Task<Void, Never>(priority: .userInitiated) { @MainActor in
                            await model.importPicked(newItem)
                        }
                    }
                }
            ), matching: .images) {
                Label("选择照片", systemImage: "photo.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(
                        Color(red: 0.94, green: 0.64, blue: 0.28),
                        in: Capsule()
                    )
                    .foregroundStyle(Color.black.opacity(0.82))
            }

            Text("光谱模拟 · 胶片颗粒 · 光晕与染料层耦合")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [
                    Color(red: 0.94, green: 0.64, blue: 0.28).opacity(0.08),
                    Color.clear
                ],
                center: .center,
                startRadius: 10,
                endRadius: 230
            )
        )
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func stockButton(title: String, value: String, systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.94, green: 0.64, blue: 0.28))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
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
