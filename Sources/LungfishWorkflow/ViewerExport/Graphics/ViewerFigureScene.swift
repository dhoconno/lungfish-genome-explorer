// ViewerFigureScene.swift - The drawing of one viewer figure as data
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A point in figure space, in points, with the origin at the top left and y growing down,
/// as in the live viewer's flipped views.
public struct ViewerFigurePoint: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in figure space, origin at its top left.
public struct ViewerFigureRect: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A colour named by role, with the role's alpha replaced when `alpha` is set, as
/// `NSColor.withAlphaComponent(_:)` replaces it.
public struct ViewerFigurePaint: Sendable, Hashable, Codable {
    public let role: ViewerFigureColorRole
    public let alpha: Double?

    public init(_ role: ViewerFigureColorRole, alpha: Double? = nil) {
        self.role = role
        self.alpha = alpha
    }

    /// The colour this paint resolves to in a theme.
    public func color(in theme: ViewerFigureTheme) -> ViewerFigureColor {
        let base = theme.color(role)
        return alpha.map { base.withAlpha($0) } ?? base
    }
}

/// Where a text run sits against its point.
public enum ViewerFigureTextAnchor: String, Sendable, Hashable, Codable, CaseIterable {
    /// The point is the left end of the baseline.
    case baselineStart
    /// The point is the middle of the baseline.
    case baselineCenter
    /// The point is the right end of the baseline.
    case baselineEnd
}

/// One line of text, drawn with `CTLineDraw` in a font named by its checked PostScript name.
public struct ViewerFigureText: Sendable, Hashable, Codable {
    public let string: String
    /// The PostScript name the font resolved to, never the name that was asked for.
    public let fontName: String
    public let fontSize: Double
    public let point: ViewerFigurePoint
    public let anchor: ViewerFigureTextAnchor
    public let paint: ViewerFigurePaint

    public init(
        string: String, fontName: String, fontSize: Double, point: ViewerFigurePoint,
        anchor: ViewerFigureTextAnchor, paint: ViewerFigurePaint
    ) {
        self.string = string
        self.fontName = fontName
        self.fontSize = fontSize
        self.point = point
        self.anchor = anchor
        self.paint = paint
    }
}

/// One drawing step. Items draw in order, so a later item covers an earlier one.
public enum ViewerFigureItem: Sendable, Hashable, Codable {
    /// Fills a rectangle.
    case fill(rect: ViewerFigureRect, paint: ViewerFigurePaint)
    /// Strokes the outline of a rectangle.
    case strokeRect(rect: ViewerFigureRect, lineWidth: Double, paint: ViewerFigurePaint)
    /// Strokes separate straight segments, each a pair of points, in one width and paint.
    case strokeSegments(segments: [ViewerFigureSegment], lineWidth: Double, paint: ViewerFigurePaint)
    /// Draws one line of text.
    case text(ViewerFigureText)
    /// Draws one call of a moved CGContext renderer with the scene's theme and frame
    /// (`ViewerFigureContextLayers.swift`). A scene with a layer must have a frame.
    case layer(ViewerFigureContextLayer)
}

/// A straight segment between two points.
public struct ViewerFigureSegment: Sendable, Hashable, Codable {
    public let from: ViewerFigurePoint
    public let to: ViewerFigurePoint

    public init(from: ViewerFigurePoint, to: ViewerFigurePoint) {
        self.from = from
        self.to = to
    }
}

/// The kind of limit that hid data from a figure (BIO ruling Q-G3, item 7).
public enum ViewerFigureOmissionKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Reads not drawn past the read row cap.
    case readRowCap
    /// Reads drawn as a fixed sample of the reads fetched.
    case readSample
    /// The annotation query stopped at its record limit (no count), or the track's row cap or height left features out (the count left out).
    case annotationLimit
    /// Reads drawn as coverage only, or bases as blocks, because the scale passed a threshold.
    case scaleMode
    /// Labels left out for lack of room.
    case labelsOmitted
    /// A font that fell back to another face.
    case fontFallback
    /// A track the figure has no builder for.
    case trackNotDrawn
}

/// One limit that hid data from a figure, with the track it hit, its reason and the count left
/// out, so the figure says what it does not show (BIO 4).
public struct ViewerFigureOmission: Sendable, Hashable, Codable, Comparable {
    /// The id of the track the limit hit.
    public let trackID: String
    public let kind: ViewerFigureOmissionKind
    /// The limit in words, with its numbers, such as `max 75 rows`.
    public let reason: String
    /// The count left out, or nil when the limit cannot know it, as for `annotationLimit`.
    public let count: Int?

    public init(trackID: String, kind: ViewerFigureOmissionKind, reason: String, count: Int?) {
        self.trackID = trackID
        self.kind = kind
        self.reason = reason
        self.count = count
    }

    /// Sorted by track, then kind, then reason and count, so a scene lists them in one order.
    public static func < (lhs: ViewerFigureOmission, rhs: ViewerFigureOmission) -> Bool {
        (lhs.trackID, lhs.kind.rawValue, lhs.reason, lhs.count ?? -1)
            < (rhs.trackID, rhs.kind.rawValue, rhs.reason, rhs.count ?? -1)
    }
}

/// The drawing of one viewer figure, built from a bundle's files and drawn by
/// `ViewerFigureRasterizer`. It names colours by role and fonts by their resolved PostScript
/// names, so one scene encodes the same in any appearance, and its JSON with sorted keys is
/// the form a scene golden takes (`Tests/Fixtures/golden/viewer-graphics/<case>.scene.json`).
public struct ViewerFigureScene: Sendable, Hashable, Codable {
    /// Raised when the meaning of a stored field changes.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    /// The figure width in points.
    public let width: Double
    /// The figure height in points.
    public let height: Double
    public let appearance: ViewerFigureAppearance
    /// The paint the whole figure is filled with before any item.
    public let background: ViewerFigurePaint
    /// The frame the tracks were built in, when the figure shows a genomic region.
    public let frame: ViewerFigureFrame?
    /// Every font the text asked for and what it resolved to, fallbacks included (BIO 4).
    public let fonts: [ViewerFigureFontResolution]
    public let items: [ViewerFigureItem]
    /// Every limit that hid data from the figure, sorted by track and kind, and empty when
    /// nothing was left out (BIO ruling Q-G3, item 10).
    public let omissions: [ViewerFigureOmission]

    public init(
        width: Double,
        height: Double,
        appearance: ViewerFigureAppearance,
        background: ViewerFigurePaint,
        frame: ViewerFigureFrame?,
        fonts: [ViewerFigureFontResolution],
        items: [ViewerFigureItem],
        omissions: [ViewerFigureOmission] = [],
        formatVersion: Int = ViewerFigureScene.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.width = width
        self.height = height
        self.appearance = appearance
        self.background = background
        self.frame = frame
        self.fonts = fonts
        self.items = items
        self.omissions = omissions.sorted()
    }

    /// The theme the scene draws in.
    public var theme: ViewerFigureTheme {
        ViewerFigureTheme(appearance: appearance)
    }

    /// The scene as a golden stores it, JSON with sorted keys, pretty printed, and a final newline.
    public func goldenJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
