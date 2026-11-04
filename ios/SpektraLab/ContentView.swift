//  ContentView.swift — one screen: the picture, then a strip of looks.
//
//  The old screen hid the films and papers behind two buttons that opened
//  list sheets. Choosing a look meant leaving the picture, reading a list of
//  names, picking one, and coming back to find out what it did. This one
//  keeps the choices on screen and shows each one on the user's own photo:
//  a horizontal strip of live thumbnails, tapped in place, like a photo
//  editor. The picture never goes away.
//
//  Long-press anywhere on the picture to see it unfiltered.

import SwiftUI
import PhotosUI
import UIKit

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
    @State private var holdingOriginal = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.labInk.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                canvas
                filterDeck
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
            Text("按当前滤镜与强度，以原图尺寸保存到相册。")
        }
    }

    // A plain HStack rather than `.toolbar { ... }`: iOS 17 has two
    // `toolbar(content:)` overloads and a bare toolbar here is ambiguous.
    private var topBar: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: pickerBinding, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.07), in: Circle())
            }

            Spacer()

            VStack(spacing: 2) {
                Text("SpektraLab")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.labCream)
                Text("FILM LAB")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(2.6)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showingExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .disabled(model.previewImage == nil)
            .opacity(model.previewImage == nil ? 0.4 : 1)
        }
        .tint(Color.labRed)
        .frame(minHeight: 56)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - the picture

    private var displayImage: UIImage? {
        holdingOriginal ? (model.originalImage ?? model.previewImage) : model.previewImage
    }

    private var canvas: some View {
        ZStack {
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            if holdingOriginal {
                Text("原图  ORIGINAL")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.labCream)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(14)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.22, pressing: { pressing in
            holdingOriginal = pressing
        }, perform: {})
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.labRed.opacity(0.14))
                    .frame(width: 96, height: 96)
                Circle()
                    .stroke(Color.labRed.opacity(0.35), lineWidth: 1)
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.labRed)
            }

            VStack(spacing: 8) {
                Text("让照片拥有胶片质感")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.labCream)
                Text("导入一张照片，左右滑动挑选滤镜\n长按画面可对比原图")
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

            Text("16 FILM LOOKS  ·  LIVE PREVIEW")
                .font(.caption2.weight(.medium))
                .tracking(1.4)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [Color.labRed.opacity(0.09), Color.clear],
                           center: .center, startRadius: 10, endRadius: 240)
        )
    }

    // MARK: - the filter strip

    private var filterDeck: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("滤镜")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.labCream)
                Text("FILTERS")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("强度 \(Int(model.intensity * 100))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(model.filters) { look in
                        FilterTile(image: model.thumbs[look.id],
                                   look: look,
                                   selected: look.id == model.selectedFilterID) {
                            model.selectFilter(look.id)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 3)
            }
            .frame(height: 104)

            HStack(spacing: 12) {
                Image(systemName: "sun.min")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { model.intensity },
                    set: { model.intensityChanged($0) }
                ), in: 0...1)
                .tint(Color.labRed)
                Image(systemName: "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            HStack(spacing: 8) {
                if model.state == .rendering || model.state == .importing {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(model.previewImage == nil
                              ? Color.secondary.opacity(0.5) : Color.labRed)
                        .frame(width: 6, height: 6)
                }
                Text(model.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.lastRenderMs > 0 {
                    Text(String(format: "%.0f ms", model.lastRenderMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Color.labPanel)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: - helpers

    private var pickerBinding: Binding<PhotosPickerItem?> {
        Binding<PhotosPickerItem?>(
            get: { pickerItem },
            set: { newItem in
                pickerItem = newItem
                if let newItem {
                    Task<Void, Never>(priority: .userInitiated) { @MainActor in
                        await model.importPicked(newItem)
                    }
                }
            }
        )
    }

    private var failureMessage: String? {
        if case .failed(let why) = model.state { return why }
        return nil
    }

    /// An error is a small dismissible notice, not a screen-sized red bar.
    /// The picture stays visible, and a failed import can simply be retried.
    @ViewBuilder
    private func notice(_ why: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.labRed)
            Text(why)
                .font(.footnote)
                .foregroundStyle(Color.labCream)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                model.dismissFailure()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.labRed.opacity(0.45), lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 232)
    }
}

// MARK: - one tile in the strip

/// A look, shown on the user's own photo. The thumbnail is generated once
/// per import by the view model, so swiping the strip costs nothing.
struct FilterTile: View {
    let image: UIImage?
    let look: FilmLook
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [
                                Color(red: look.swatch[0],
                                      green: look.swatch[1],
                                      blue: look.swatch[2]),
                                Color.black.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Color.labRed : Color.white.opacity(0.10),
                                lineWidth: selected ? 2.5 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.labRed)
                            .background(Color.labCream, in: Circle())
                            .padding(4)
                    }
                }

                Text(look.name)
                    .font(.caption2.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.labRed : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: selected)
    }
}
