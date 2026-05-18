// HexColor+AppKit.swift - App-owned platform color adapters
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

extension HexColor {
    init(nsColor color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            self = .fallbackGray
            return
        }
        self.init(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent),
            alpha: Double(rgb.alphaComponent)
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    var cgColor: CGColor {
        nsColor.cgColor
    }
}

extension AppSettings {
    /// Returns an NSColor for the given annotation type, using the user's configured hex color.
    func annotationColor(for type: AnnotationType) -> NSColor {
        annotationHexColor(for: type).nsColor
    }

    /// Converts a hex string (e.g. "#339933") to an NSColor.
    nonisolated static func color(from hexString: String) -> NSColor {
        hexColor(from: hexString).nsColor
    }

    /// Converts an NSColor to a hex string (e.g. "#339933").
    nonisolated static func hexString(from color: NSColor) -> String {
        HexColor(nsColor: color).hexString
    }
}

extension SequenceAppearance {
    func nsColor(forBase base: Character) -> NSColor {
        color(forBase: base).nsColor
    }

    mutating func setColor(_ color: NSColor, forBase base: Character) {
        baseColors[String(base).uppercased()] = HexColor(nsColor: color).hexString
    }
}

extension SemanticColors.Status {
    static var successNSColor: NSColor { .systemGreen }
    static var failureNSColor: NSColor { .systemRed }
    static var warningNSColor: NSColor { .systemOrange }
    static var infoNSColor: NSColor { .systemBlue }
}

extension SemanticColors.Quality {
    static var highNSColor: NSColor { .systemGreen }
    static var mediumNSColor: NSColor { .systemYellow }
    static var lowNSColor: NSColor { .systemOrange }
    static var veryLowNSColor: NSColor { .systemRed }

    static func nsColor(for score: Int) -> NSColor {
        if score >= 30 { return highNSColor }
        if score >= 20 { return mediumNSColor }
        if score >= 10 { return lowNSColor }
        return veryLowNSColor
    }
}
