// ViewerFigureTrackText.swift - CoreText labels for the track renderers that draw into a CGContext
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation

/// Text the track renderers draw straight into a `CGContext`, with CoreText and never AppKit.
///
/// The renderers drew their labels with `NSString.draw(at:withAttributes:)` in the system font.
/// These functions keep that face, the system UI font CoreText gives for `.system`, and place a
/// line as `NSString.draw(at:)` placed it in the live flipped view, with the top of its line box
/// at the point and its baseline one ascent below, taken from the font's metrics (13.28 deviation
/// 5). The context must have a top-left origin with y down, as the live view and the figure
/// rasterizer have. The functions keep no state.
public enum ViewerFigureTrackText {
    /// The faces the live renderers asked AppKit for.
    public enum Face: Sendable, Hashable {
        /// `NSFont.systemFont(ofSize:)`.
        case system
        /// `NSFont.systemFont(ofSize:weight: .medium)`.
        case systemMedium
        /// `NSFont.monospacedDigitSystemFont(ofSize:weight: .regular)`.
        case monospacedDigitSystem
    }

    /// The weight AppKit gives `.medium`, `NSFont.Weight.medium.rawValue`.
    public static let mediumWeight = 0.23

    /// The system UI font in `face` at `size` points.
    public static func font(_ face: Face, size: Double) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            ?? CTFontCreateWithName(ViewerFigureFonts.fallbackName as CFString, CGFloat(size), nil)
        let attributes: [CFString: Any]
        switch face {
        case .system:
            return base
        case .systemMedium:
            attributes = [kCTFontTraitsAttribute: [kCTFontWeightTrait: mediumWeight] as CFDictionary]
        case .monospacedDigitSystem:
            let monospacedNumbers: [CFString: Any] = [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]
            attributes = [kCTFontFeatureSettingsAttribute: [monospacedNumbers as CFDictionary] as CFArray]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
    }

    /// The typographic width of `string` in `font`, as `NSString.size(withAttributes:)` gives it.
    public static func width(_ string: String, font: CTFont) -> Double {
        ViewerFigureFonts.metrics(string, font: font).width
    }

    /// The height of one line box of `font`: ascent, descent and leading.
    public static func lineHeight(_ font: CTFont) -> Double {
        Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// Draws one line with the top of its line box at `topLeft`, in `color`.
    public static func draw(_ string: String, font: CTFont, color: CGColor, topLeft: CGPoint, in context: CGContext) {
        draw(ViewerFigureFonts.line(string, font: font), font: font, color: color, topLeft: topLeft, in: context)
    }

    /// Draws one line inside `rect`, cut at its tail with an ellipsis when it is wider than the
    /// rectangle, as `NSString.draw(in:)` with `.byTruncatingTail` drew a sample name.
    public static func drawTruncatingTail(_ string: String, font: CTFont, color: CGColor, in rect: CGRect, context: CGContext) {
        guard rect.width > 0 else { return }
        var line = ViewerFigureFonts.line(string, font: font)
        if width(string, font: font) > Double(rect.width) {
            let ellipsis = ViewerFigureFonts.line("\u{2026}", font: font)
            guard let cut = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) else { return }
            line = cut
        }
        context.saveGState()
        context.clip(to: rect)
        draw(line, font: font, color: color, topLeft: rect.origin, in: context)
        context.restoreGState()
    }

    private static func draw(_ line: CTLine, font: CTFont, color: CGColor, topLeft: CGPoint, in context: CGContext) {
        let baseline = topLeft.y + CTFontGetAscent(font)
        context.saveGState()
        context.setFillColor(color)
        context.translateBy(x: topLeft.x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
