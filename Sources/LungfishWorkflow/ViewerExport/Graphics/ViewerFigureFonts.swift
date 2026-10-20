// ViewerFigureFonts.swift - Fonts for viewer figures, by checked PostScript name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation

/// What a figure asked for and the face CoreText gave it. A scene keeps every resolution,
/// so a fallback is recorded and never hidden (BIO 4).
public struct ViewerFigureFontResolution: Sendable, Hashable, Codable {
    /// The first PostScript name asked for.
    public let requested: String
    /// The PostScript name of the face in use.
    public let resolved: String
    public let size: Double
    /// True when the face in use is not the one asked for first.
    public let fallback: Bool

    public init(requested: String, resolved: String, size: Double) {
        self.requested = requested
        self.resolved = resolved
        self.size = size
        self.fallback = requested != resolved
    }
}

/// A font no name could provide.
public enum ViewerFigureFontError: Error, Hashable, LocalizedError {
    case noFaceResolved(names: [String], size: Double)

    public var errorDescription: String? {
        switch self {
        case .noFaceResolved(let names, let size):
            "None of the fonts \(names.joined(separator: ", ")) is installed at size \(size), so the figure was not drawn."
        }
    }
}

/// The width and vertical metrics of one line of text.
public struct ViewerFigureTextMetrics: Sendable, Hashable {
    public let width: Double
    public let ascent: Double
    public let descent: Double
    public let leading: Double
}

/// Fonts for figure text, asked for by PostScript name through CoreText, never `NSFont`.
///
/// CoreText gives some face for any name, so a missing font would silently become another face
/// with other metrics. Every lookup checks the name it got back, as `PrimerOrderSheetWriter`
/// does, and tries the next name, ending at `fallbackName`, which every macOS install holds.
public enum ViewerFigureFonts {
    /// The last face tried when no name asked for is installed.
    public static let fallbackName = "Helvetica"

    /// The face with exactly this PostScript name, or nil when it is not installed.
    public static func font(named postScriptName: String, size: Double) -> CTFont? {
        let font = CTFontCreateWithName(postScriptName as CFString, CGFloat(size), nil)
        return CTFontCopyPostScriptName(font) as String == postScriptName ? font : nil
    }

    /// The first installed face among `names`, then `fallbackName`, with the record of what was
    /// asked for and what was used.
    public static func resolve(
        _ names: [String], size: Double
    ) throws(ViewerFigureFontError) -> (font: CTFont, resolution: ViewerFigureFontResolution) {
        let candidates = names.last == fallbackName ? names : names + [fallbackName]
        for name in candidates {
            if let font = font(named: name, size: size) {
                return (font, ViewerFigureFontResolution(requested: candidates[0], resolved: name, size: size))
            }
        }
        throw .noFaceResolved(names: candidates, size: size)
    }

    /// A line of `string` in `font`, with the CoreText attribute that makes it take its colour
    /// from the context's fill colour.
    public static func line(_ string: String, font: CTFont) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
        return CTLineCreateWithAttributedString(attributed!)
    }

    /// The typographic width, ascent, descent and leading of `string` in `font`.
    public static func metrics(_ string: String, font: CTFont) -> ViewerFigureTextMetrics {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line(string, font: font), &ascent, &descent, &leading)
        return ViewerFigureTextMetrics(
            width: Double(width), ascent: Double(ascent), descent: Double(descent), leading: Double(leading)
        )
    }
}
