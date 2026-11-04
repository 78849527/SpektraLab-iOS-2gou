//  FilmLook.swift — the film looks, and the Core Image chain that draws them.
//
//  This file replaces the whole C++ engine path for the interactive part of
//  the app. Every look is a set of numbers, and every number is applied by a
//  filter that ships with iOS. There is no resource archive to download, no
//  `extern "C"` boundary to cross, no colour-space conversion into a working
//  space, and no Metal texture to blit back. A photo can no longer fail to
//  import because a profile file did not arrive over the network.
//
//  The chain is deliberately built from `CIFilter(name:)` rather than the
//  typed subclasses: on iOS the typed `CIExposureAdjust()` / `CIToneCurve()`
//  factories exist, but taking the name keeps every step behind one guard,
//  and `inputKeys.contains` means a key that a given OS build does not know
//  is skipped instead of raising an NSException (which Swift cannot catch,
//  and which would take the process down as SIGABRT).

import Foundation
import CoreImage
import UIKit

/// One film look. A value type: reading the catalogue from SwiftUI is safe.
struct FilmLook: Identifiable, Sendable {
    let id: String
    /// The name a person reads.
    let name: String
    /// A short latin label, for the status line.
    let tag: String

    /// Exposure in stops.
    let exposure: Double
    /// `CIColorControls` contrast (1 = unchanged).
    let contrast: Double
    /// `CIColorControls` saturation (1 = unchanged).
    let saturation: Double
    /// `CIColorControls` brightness.
    let brightness: Double
    /// Warmth, as a shift away from a 6500 K neutral. Positive is warm.
    let temperature: Double
    /// Green/magenta shift.
    let tint: Double
    /// Lifted blacks and rolled highlights: 0…1.
    let fade: Double
    /// `CIVignette` intensity.
    let vignette: Double
    /// Grain opacity.
    let grain: Double
    /// Black and white.
    let mono: Bool
    /// A trace of sepia on top of a monochrome look.
    let sepia: Double
    /// Only used for the tile shown before a photo has been imported.
    let swatch: [Double]

    var isOriginal: Bool { id == "original" }
}

extension FilmLook {

    /// The looks, in the order the strip shows them.
    ///
    /// The first is the untouched frame: a filter strip without a way back
    /// to zero is a trap. The rest are grouped by colour family — warm
    /// negative, saturated, cool, faded, then black and white — so swiping
    /// left moves through related looks rather than jumping at random.
    static let catalog: [FilmLook] = [
        FilmLook(id: "original", name: "原片", tag: "ORIGINAL",
                 exposure: 0, contrast: 1, saturation: 1, brightness: 0,
                 temperature: 0, tint: 0, fade: 0, vignette: 0, grain: 0,
                 mono: false, sepia: 0, swatch: [0.42, 0.43, 0.45]),

        FilmLook(id: "portra", name: "奶油 400", tag: "PORTRA 400",
                 exposure: 0.10, contrast: 0.94, saturation: 0.94, brightness: 0.012,
                 temperature: 900, tint: 6, fade: 0.32, vignette: 0.16, grain: 0.09,
                 mono: false, sepia: 0, swatch: [0.86, 0.68, 0.52]),

        FilmLook(id: "gold", name: "金 200", tag: "GOLD 200",
                 exposure: 0.12, contrast: 1.04, saturation: 1.14, brightness: 0.008,
                 temperature: 1500, tint: 10, fade: 0.16, vignette: 0.22, grain: 0.12,
                 mono: false, sepia: 0, swatch: [0.90, 0.66, 0.30]),

        FilmLook(id: "ektar", name: "浓郁 100", tag: "EKTAR 100",
                 exposure: -0.02, contrast: 1.18, saturation: 1.38, brightness: 0,
                 temperature: -150, tint: -4, fade: 0.05, vignette: 0.14, grain: 0.05,
                 mono: false, sepia: 0, swatch: [0.80, 0.29, 0.24]),

        FilmLook(id: "velvia", name: "风光 50", tag: "VELVIA 50",
                 exposure: -0.06, contrast: 1.26, saturation: 1.50, brightness: -0.01,
                 temperature: -300, tint: -8, fade: 0, vignette: 0.28, grain: 0.04,
                 mono: false, sepia: 0, swatch: [0.20, 0.47, 0.40]),

        FilmLook(id: "superia", name: "青绿 400", tag: "SUPERIA 400",
                 exposure: 0.06, contrast: 1.02, saturation: 1.05, brightness: 0.006,
                 temperature: -600, tint: -14, fade: 0.20, vignette: 0.18, grain: 0.12,
                 mono: false, sepia: 0, swatch: [0.32, 0.55, 0.47]),

        FilmLook(id: "cinestill", name: "夜色 800T", tag: "CINESTILL 800T",
                 exposure: 0.04, contrast: 1.08, saturation: 0.88, brightness: 0,
                 temperature: -1100, tint: -8, fade: 0.28, vignette: 0.34, grain: 0.16,
                 mono: false, sepia: 0, swatch: [0.19, 0.32, 0.48]),

        FilmLook(id: "kodachrome", name: "柯达 64", tag: "KODACHROME 64",
                 exposure: -0.02, contrast: 1.16, saturation: 1.22, brightness: -0.004,
                 temperature: 250, tint: 3, fade: 0.10, vignette: 0.20, grain: 0.10,
                 mono: false, sepia: 0, swatch: [0.72, 0.35, 0.27]),

        FilmLook(id: "polaroid", name: "宝丽来", tag: "POLAROID",
                 exposure: 0.14, contrast: 0.88, saturation: 0.78, brightness: 0.02,
                 temperature: 350, tint: -20, fade: 0.55, vignette: 0.42, grain: 0.14,
                 mono: false, sepia: 0, swatch: [0.80, 0.78, 0.66]),

        FilmLook(id: "daylight", name: "日系", tag: "SOFT DAYLIGHT",
                 exposure: 0.16, contrast: 0.90, saturation: 0.82, brightness: 0.030,
                 temperature: 200, tint: 2, fade: 0.40, vignette: 0.08, grain: 0.05,
                 mono: false, sepia: 0, swatch: [0.87, 0.88, 0.80]),

        FilmLook(id: "ccd", name: "复古 CCD", tag: "RETRO CCD",
                 exposure: 0.08, contrast: 1.10, saturation: 1.12, brightness: 0.004,
                 temperature: -350, tint: 18, fade: 0.22, vignette: 0.20, grain: 0.18,
                 mono: false, sepia: 0, swatch: [0.48, 0.40, 0.62]),

        FilmLook(id: "faded", name: "褪色杂志", tag: "FADED PRINT",
                 exposure: 0.06, contrast: 0.86, saturation: 0.70, brightness: 0.014,
                 temperature: 600, tint: 6, fade: 0.60, vignette: 0.18, grain: 0.12,
                 mono: false, sepia: 0, swatch: [0.74, 0.65, 0.55]),

        FilmLook(id: "teal", name: "青橙电影", tag: "TEAL & ORANGE",
                 exposure: 0, contrast: 1.14, saturation: 1.16, brightness: -0.004,
                 temperature: -450, tint: -6, fade: 0.18, vignette: 0.30, grain: 0.07,
                 mono: false, sepia: 0, swatch: [0.24, 0.44, 0.52]),

        FilmLook(id: "trix", name: "黑白 400", tag: "TRI-X 400",
                 exposure: 0.02, contrast: 1.30, saturation: 1, brightness: -0.010,
                 temperature: 0, tint: 0, fade: 0.12, vignette: 0.30, grain: 0.28,
                 mono: true, sepia: 0, swatch: [0.55, 0.55, 0.55]),

        FilmLook(id: "hp5", name: "银盐 400", tag: "HP5 PLUS",
                 exposure: 0.04, contrast: 1.04, saturation: 1, brightness: 0.018,
                 temperature: 0, tint: 0, fade: 0.35, vignette: 0.20, grain: 0.18,
                 mono: true, sepia: 0.06, swatch: [0.68, 0.65, 0.58]),

        FilmLook(id: "noir", name: "高反差黑白", tag: "NOIR",
                 exposure: -0.02, contrast: 1.50, saturation: 1, brightness: -0.030,
                 temperature: 0, tint: 0, fade: 0, vignette: 0.42, grain: 0.12,
                 mono: true, sepia: 0, swatch: [0.30, 0.30, 0.30]),
    ]

    static let defaultID = "portra"

    static func look(withID id: String) -> FilmLook {
        catalog.first { $0.id == id } ?? catalog[0]
    }
}

/// Draws a look. Main-actor isolated because `CIImage` is not `Sendable`;
/// the view model is on the main actor too, so nothing crosses a boundary.
@MainActor
enum FilmRenderer {

    /// Apply a look to a frame.
    ///
    /// `intensity` is a single cross-fade between the untouched input and the
    /// fully graded result, rather than a per-parameter scaling. It is both
    /// cheaper to reason about and exact at the two ends: 0 is the original
    /// frame, 1 is the look as designed.
    static func render(_ look: FilmLook, on input: CIImage, intensity: Double) -> CIImage {
        guard !look.isOriginal else { return input }
        let t = min(max(intensity, 0), 1)
        guard t > 0.001 else { return input }

        var image = input

        image = apply("CIExposureAdjust", image, ["inputEV": look.exposure])

        image = apply("CITemperatureAndTint", image, [
            "inputNeutral": CIVector(x: CGFloat(6500 - look.temperature), y: CGFloat(look.tint)),
            "inputTargetNeutral": CIVector(x: 6500, y: 0)
        ])

        image = apply("CIColorControls", image, [
            "inputSaturation": look.mono ? 0 : look.saturation,
            "inputContrast": look.contrast,
            "inputBrightness": look.brightness
        ])

        if look.sepia > 0.001 {
            image = apply("CISepiaTone", image, ["inputIntensity": look.sepia])
        }

        if look.fade > 0.001 {
            let f = look.fade
            image = apply("CIToneCurve", image, [
                "inputPoint0": CIVector(x: 0.00, y: CGFloat(0.10 * f)),
                "inputPoint1": CIVector(x: 0.25, y: CGFloat(0.25 + 0.035 * f)),
                "inputPoint2": CIVector(x: 0.50, y: CGFloat(0.50 + 0.005 * f)),
                "inputPoint3": CIVector(x: 0.75, y: CGFloat(0.75 - 0.025 * f)),
                "inputPoint4": CIVector(x: 1.00, y: CGFloat(1.00 - 0.035 * f))
            ])
        }

        if look.vignette > 0.001 {
            image = apply("CIVignette", image, [
                "inputIntensity": look.vignette,
                "inputRadius": 1.35
            ])
        }

        if look.grain > 0.001 {
            image = addGrain(image, amount: look.grain)
        }

        guard t < 0.999 else { return image }

        let translucent = apply("CIColorMatrix", image, [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(t))
        ])
        return composite(translucent, over: input, fallback: image)
    }

    /// One filter step. An unknown filter or an unknown key is skipped.
    ///
    /// `setValue(_:forKey:)` raises an Objective-C exception for a key the
    /// filter does not declare, and Swift cannot catch it. Checking
    /// `inputKeys` first is what makes a missing key harmless.
    private static func apply(_ name: String, _ input: CIImage,
                              _ params: [String: Any]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return input }
        filter.setDefaults()
        if filter.inputKeys.contains(kCIInputImageKey) {
            filter.setValue(input, forKey: kCIInputImageKey)
        }
        for (key, value) in params where filter.inputKeys.contains(key) {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage ?? input
    }

    /// A deterministic grain layer, bound to the frame's own extent.
    ///
    /// `CIRandomGenerator` has an infinite extent and the same value at the
    /// same coordinate on every render, so the grain does not shimmer as the
    /// slider moves. It is desaturated, given a low alpha, and composited
    /// over the frame with source-over.
    private static func addGrain(_ input: CIImage, amount: Double) -> CIImage {
        guard let generator = CIFilter(name: "CIRandomGenerator"),
              let noise = generator.outputImage else { return input }
        let cropped = noise.cropped(to: input.extent)
        let gray = apply("CIColorMonochrome", cropped, [
            "inputColor": CIColor(red: 0.5, green: 0.5, blue: 0.5),
            "inputIntensity": 1.0
        ])
        let soft = apply("CIColorMatrix", gray, [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(amount, 0.40)))
        ])
        return composite(soft, over: input, fallback: input)
    }

    private static func composite(_ foreground: CIImage, over background: CIImage,
                                  fallback: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CISourceOverCompositing") else { return fallback }
        filter.setValue(foreground, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: "inputBackgroundImage")
        return filter.outputImage ?? fallback
    }
}
