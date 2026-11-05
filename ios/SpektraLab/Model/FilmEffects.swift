//  FilmEffects.swift — the film's own edge and the camera's date back.
//
//  Both are real engine features, not overlays. They are exposed on the
//  negative: the rebate, sprocket holes, edge print, frame number and date
//  all receive the same development, grain and halation as the photograph.
//  The iOS UI only picks the physical stock format and the camera's back.

import Foundation

/// One gate the engine can lay the picture into.
struct FilmGate: Identifiable, Hashable, Sendable {
    /// The engine's `overscan_format` value.
    let id: String
    let title: String
    let detail: String
    let longEdgeMM: Double
    let shortEdgeMM: Double
    let supportsDateBack: Bool

    /// Long edge over short edge. The engine accepts either orientation.
    var aspect: CGFloat { CGFloat(longEdgeMM / shortEdgeMM) }
}

enum FilmGateCatalog {
    static let automaticID = "auto"

    /// The measured gates shipped by the engine. `135` is first because it is
    /// the one with real sprockets and a DX rebate; the 120 gates follow.
    static let gates: [FilmGate] = [
        FilmGate(id: "135", title: "35 mm", detail: "135 · 齿孔 / DX / 片边字",
                 longEdgeMM: 36.25, shortEdgeMM: 24.3, supportsDateBack: true),
        FilmGate(id: "135_half", title: "半格", detail: "135 半格 · 竖构图",
                 longEdgeMM: 24.0, shortEdgeMM: 18.0, supportsDateBack: true),
        FilmGate(id: "120_645", title: "120 / 645", detail: "6×4.5 · 片边字 / 日期",
                 longEdgeMM: 56.0, shortEdgeMM: 41.5, supportsDateBack: true),
        FilmGate(id: "120_6x6", title: "120 / 6×6", detail: "6×6 · 片边字 / 日期",
                 longEdgeMM: 56.0, shortEdgeMM: 56.0, supportsDateBack: true),
        FilmGate(id: "120_6x7", title: "120 / 6×7", detail: "6×7 · 片边字 / 日期",
                 longEdgeMM: 69.5, shortEdgeMM: 56.0, supportsDateBack: true),
        FilmGate(id: "120_6x8", title: "120 / 6×8", detail: "6×8 · 片边字 / 日期",
                 longEdgeMM: 76.0, shortEdgeMM: 56.0, supportsDateBack: true),
        FilmGate(id: "120_6x9", title: "120 / 6×9", detail: "6×9 · 片边字 / 日期",
                 longEdgeMM: 84.0, shortEdgeMM: 56.0, supportsDateBack: true),
        FilmGate(id: "135_xpan", title: "XPan", detail: "135 全景 · 无日期后背",
                 longEdgeMM: 65.0, shortEdgeMM: 24.0, supportsDateBack: false),
        FilmGate(id: "120_6x12", title: "120 / 6×12", detail: "全景 · 无日期后背",
                 longEdgeMM: 112.0, shortEdgeMM: 56.0, supportsDateBack: false),
        FilmGate(id: "120_6x17", title: "120 / 6×17", detail: "全景 · 无日期后背",
                 longEdgeMM: 168.0, shortEdgeMM: 56.0, supportsDateBack: false),
    ]

    static func gate(id: String) -> FilmGate? {
        gates.first { $0.id == id }
    }

    /// The automatic choice: the measured gate closest to the photograph's
    /// long/short ratio. Panoramic gates are included, so an XPan crop stays
    /// an XPan crop instead of being forced back to 3:2.
    static func resolve(selection: String, imageAspect: CGFloat?) -> FilmGate {
        if let explicit = gate(id: selection) { return explicit }
        let source = max(imageAspect ?? (3.0 / 2.0), 1.0)
        return gates.min {
            abs(log(Double(source / $0.aspect))) < abs(log(Double(source / $1.aspect)))
        } ?? gates[0]
    }
}

enum DateBackStyle: String, CaseIterable, Identifiable, Sendable {
    case lcd
    case dots

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lcd: "液晶七段"
        case .dots: "点阵"
        }
    }
}

enum DateBackPlacement: String, CaseIterable, Identifiable, Sendable {
    case frame
    case rebate

    var id: String { rawValue }
    var title: String {
        switch self {
        case .frame: "画面内"
        case .rebate: "片边之间"
        }
    }
}

enum DateBackCorner: String, CaseIterable, Identifiable, Sendable {
    case br, bl, tr, tl

    var id: String { rawValue }
    var title: String {
        switch self {
        case .br: "右下"
        case .bl: "左下"
        case .tr: "右上"
        case .tl: "左上"
        }
    }
}
