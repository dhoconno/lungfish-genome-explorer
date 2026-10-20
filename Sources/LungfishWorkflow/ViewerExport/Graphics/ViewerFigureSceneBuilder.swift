// ViewerFigureSceneBuilder.swift - Builds a viewer figure scene from its tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreText
import Foundation

/// One track of a figure, such as the ruler or the sequence. It reads what it needs from the
/// bundle's files through LungfishIO readers and adds its items to the canvas, inside its area.
public protocol ViewerFigureTrackBuilding: Sendable {
    /// The height the track takes, in points.
    var height: Double { get }

    /// Adds the track's items. The builder calls it off the main actor.
    func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws
}

/// The items of a scene in draw order, and every font their text resolved.
public struct ViewerFigureCanvas: Sendable {
    public private(set) var items: [ViewerFigureItem] = []
    public private(set) var fonts: [ViewerFigureFontResolution] = []

    public init() {}

    public mutating func fill(_ rect: ViewerFigureRect, _ paint: ViewerFigurePaint) {
        items.append(.fill(rect: rect, paint: paint))
    }

    public mutating func strokeRect(_ rect: ViewerFigureRect, lineWidth: Double, _ paint: ViewerFigurePaint) {
        items.append(.strokeRect(rect: rect, lineWidth: lineWidth, paint: paint))
    }

    /// Adds the segments as one item. An empty list adds nothing.
    public mutating func strokeSegments(_ segments: [ViewerFigureSegment], lineWidth: Double, _ paint: ViewerFigurePaint) {
        guard !segments.isEmpty else { return }
        items.append(.strokeSegments(segments: segments, lineWidth: lineWidth, paint: paint))
    }

    /// Resolves a font by checked name and records the resolution once, in order of first use.
    /// The font is returned for measuring and never stored.
    public mutating func font(_ names: [String], size: Double) throws(ViewerFigureFontError) -> CTFont {
        let (font, resolution) = try ViewerFigureFonts.resolve(names, size: size)
        if fonts.firstIndex(of: resolution) == nil {
            fonts.append(resolution)
        }
        return font
    }

    /// The typographic width of `string` in the first installed face among `names`.
    public mutating func textWidth(_ string: String, fontNames names: [String], size: Double) throws(ViewerFigureFontError) -> Double {
        ViewerFigureFonts.metrics(string, font: try font(names, size: size)).width
    }

    /// Adds one line of text in the first installed face among `names`, recording that face.
    public mutating func text(
        _ string: String, fontNames names: [String], size: Double, at point: ViewerFigurePoint,
        anchor: ViewerFigureTextAnchor, _ paint: ViewerFigurePaint
    ) throws(ViewerFigureFontError) {
        let face = try font(names, size: size)
        let name = CTFontCopyPostScriptName(face) as String
        items.append(.text(ViewerFigureText(
            string: string, fontName: name, fontSize: size, point: point, anchor: anchor, paint: paint
        )))
    }
}

/// Builds a figure scene by stacking its tracks from the top, each across the frame's width.
public enum ViewerFigureSceneBuilder {
    /// Builds the scene off the main actor. Each track reads its own inputs, and a cancelled task
    /// stops between tracks.
    nonisolated public static func build(
        frame: ViewerFigureFrame,
        appearance: ViewerFigureAppearance,
        tracks: [any ViewerFigureTrackBuilding],
        background: ViewerFigurePaint = ViewerFigurePaint(.textBackground)
    ) async throws -> ViewerFigureScene {
        var canvas = ViewerFigureCanvas()
        var top = 0.0
        let width = Double(frame.pixelWidth)
        for track in tracks {
            try Task.checkCancellation()
            let area = ViewerFigureRect(x: 0, y: top, width: width, height: track.height)
            try await track.build(into: &canvas, frame: frame, area: area)
            top += track.height
        }
        return ViewerFigureScene(
            width: width, height: top, appearance: appearance, background: background,
            frame: frame, fonts: canvas.fonts, items: canvas.items
        )
    }
}
