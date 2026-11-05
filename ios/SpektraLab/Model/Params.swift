//  Params.swift — the engine's parameters, as Swift values.
//
//  The engine's surface is JSON (spk_engine.h rule 3), so every control in the
//  app is a key in a delta object. This file is the typed side of that: it
//  names the keys the app drives, gives them ranges and units, and turns a
//  slider's value into the JSON the engine wants.
//
//  **The key names are the engine's, not ours.** They come from the upstream
//  parameter schema (`spk_params_schema`), and the engine refuses a key it does
//  not know. So a rename here is a behaviour change, not a refactor.

import Foundation

/// One parameter value, as the engine's JSON sees it.
enum ParamValue: Codable, Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                              debugDescription: "not a number, bool or string")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    var doubleValue: Double? {
        if case .number(let v) = self { return v }
        if case .bool(let v) = self { return v ? 1 : 0 }
        return nil
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

/// The parameters this app drives, with their ranges.
///
/// These are the ones the Android port drives too, and the ones the engine
/// models physically. Note what is *not* here: aperture, shutter speed and
/// ISO are not simulation inputs in this engine — they are metadata the date
/// back prints. Exposure is `exposure_compensation_ev` plus `auto_exposure`;
/// white balance is the enlarger's filter pack, not a camera WB.
enum FilmParam: String, CaseIterable, Sendable {
    /// Which film stock. A profile name; the engine loads
    /// `<resources>/profiles/<name>.json`.
    case filmStock = "film_stock"
    /// Which paper. Same scheme.
    case printStock = "print_stock"
    /// Exposure compensation in stops.
    case exposureCompensation = "exposure_compensation_ev"
    /// Whether the engine computes the exposure itself.
    case autoExposure = "auto_exposure"
    /// Grain strength, 0…1.
    case grainAmount = "grain_amount"
    /// Whether the grain layer is on.
    case grainActive = "grain_active"
    /// Halation strength, 0…1.
    case halationAmount = "halation_amount"
    case halationActive = "halation_active"
    /// Veiling glare strength, 0…1.
    case glareAmount = "glare_amount"
    case glareActive = "glare_active"
    /// The enlarger's filter pack, as the M/Y shifts the engine models.
    case mFilterShift = "m_filter_shift"
    case yFilterShift = "y_filter_shift"
    /// The print's density curve gamma.
    case densityCurveGamma = "density_curve_gamma"

    var key: String { rawValue }
}

/// One slider in the UI.
struct ParamControl: Identifiable, Sendable {
    let id: String
    let title: String
    /// The engine's key.
    let key: String
    let range: ClosedRange<Double>
    /// The value the engine starts from.
    let defaultValue: Double
    /// Whether the engine can change this in place, or has to rebuild the
    /// pipeline. The engine says which, in the `set_params` reply; this is the
    /// app's own note of the same thing, for the UI's benefit.
    let isLive: Bool

    init(_ param: FilmParam, title: String, range: ClosedRange<Double>,
         defaultValue: Double, isLive: Bool = true) {
        self.id = param.rawValue
        self.title = title
        self.key = param.rawValue
        self.range = range
        self.defaultValue = defaultValue
        self.isLive = isLive
    }
}

/// The controls the iOS app shows, in the order it shows them.
enum ParamCatalog {
    static let all: [ParamControl] = [
        ParamControl(.exposureCompensation, title: "曝光补偿", range: -3...3, defaultValue: 0),
        ParamControl(.grainAmount, title: "颗粒", range: 0...1, defaultValue: 0.35),
        ParamControl(.halationAmount, title: "光晕", range: 0...1, defaultValue: 0.25),
        ParamControl(.glareAmount, title: "眩光", range: 0...1, defaultValue: 0.15),
        ParamControl(.densityCurveGamma, title: "密度曲线", range: 0.2...0.8, defaultValue: 0.45),
        ParamControl(.mFilterShift, title: "滤色包 M", range: -1...1, defaultValue: 0),
        ParamControl(.yFilterShift, title: "滤色包 Y", range: -1...1, defaultValue: 0),
    ]

    static func control(for key: String) -> ParamControl? {
        all.first { $0.key == key }
    }
}

/// The default value of every control, as a delta the engine accepts on open.
enum ParamDefaults {
    static func delta(film: String, paper: String) -> [String: ParamValue] {
        var delta: [String: ParamValue] = [
            // Match the desktop preview host's colour contract.
            "input_color_space": .string("ProPhoto RGB"),
            "input_cctf_decoding": .bool(false),
            "output_color_space": .string("sRGB"),
            "output_cctf_encoding": .bool(true),
            FilmParam.filmStock.key: .string(film),
            FilmParam.printStock.key: .string(paper),
            FilmParam.autoExposure.key: .bool(true),
            FilmParam.grainActive.key: .bool(true),
            FilmParam.halationActive.key: .bool(true),
            FilmParam.glareActive.key: .bool(true),
        ]
        for control in ParamCatalog.all {
            delta[control.key] = .number(control.defaultValue)
        }
        return delta
    }
}
