// MSADistanceColorScale.swift - Single-hue OKLab ramp and text colour choice for the distance matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// An sRGB colour with components in 0...1.
public struct MSADistanceRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = MSADistanceRGB(red: 0, green: 0, blue: 0)
    public static let white = MSADistanceRGB(red: 1, green: 1, blue: 1)

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ channel: Double) -> Double {
        let value = channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
        return min(max(value, 0), 1)
    }
}

/// A colour in the OKLab perceptual space (Bjorn Ottosson, 2020).
public struct MSADistanceOKLab: Equatable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    public init(_ rgb: MSADistanceRGB) {
        let r = MSADistanceRGB.linear(rgb.red)
        let g = MSADistanceRGB.linear(rgb.green)
        let bl = MSADistanceRGB.linear(rgb.blue)
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    public var rgb: MSADistanceRGB {
        let lc = l + 0.3963377774 * a + 0.2158037573 * b
        let mc = l - 0.1055613458 * a - 0.0638541728 * b
        let sc = l - 0.0894841775 * a - 1.2914855480 * b
        let lv = lc * lc * lc, mv = mc * mc * mc, sv = sc * sc * sc
        let r = 4.0767416621 * lv - 3.3077115913 * mv + 0.2309699292 * sv
        let g = -1.2684380046 * lv + 2.6097574011 * mv - 0.3413193965 * sv
        let bl = -0.0041960863 * lv - 0.7034186147 * mv + 1.7076147010 * sv
        return MSADistanceRGB(
            red: MSADistanceRGB.encoded(r),
            green: MSADistanceRGB.encoded(g),
            blue: MSADistanceRGB.encoded(bl)
        )
    }

    func interpolated(to other: MSADistanceOKLab, fraction t: Double) -> MSADistanceOKLab {
        MSADistanceOKLab(l: l + (other.l - l) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }
}

public enum MSADistanceAppearance: CaseIterable, Sendable {
    case light, dark

    @MainActor
    public init(_ appearance: NSAppearance) {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        self = (match == .darkAqua || match == .accessibilityHighContrastDarkAqua) ? .dark : .light
    }
}

/// Maps matrix values onto one indigo ramp (rulings P8 and U6).
///
/// The ramp runs in OKLab from just off the pane background to deep indigo
/// in light mode and to bright indigo in dark mode, so a higher value always
/// sits further from the background. Diagonal, `nan` and `inf` cells are off
/// the scale and drawn by the grid with a neutral fill, no fill and a hatch.
public struct MSADistanceColorScale: Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    /// The ramp starts this far along so the lowest value never matches the
    /// empty background used for `nan`.
    static let rampFloor = 0.1

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    /// The data range of the finite off-diagonal values, or 0...1 when
    /// `fixedUnitRange` is on.
    public init(values: [[Double]], fixedUnitRange: Bool) {
        if fixedUnitRange {
            self.init(lower: 0, upper: 1)
            return
        }
        var lowest = Double.infinity
        var highest = -Double.infinity
        for (row, line) in values.enumerated() {
            for (column, value) in line.enumerated() where row != column && value.isFinite {
                lowest = min(lowest, value)
                highest = max(highest, value)
            }
        }
        if lowest > highest {
            self.init(lower: 0, upper: 1)
        } else {
            self.init(lower: lowest, upper: highest)
        }
    }

    /// Position of a value on the ramp in 0...1, or nil for `nan` and `inf`.
    public func normalized(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let span = upper - lower
        guard span > 0 else { return 0.5 }
        return min(max((value - lower) / span, 0), 1)
    }

    public func fill(for value: Double, appearance: MSADistanceAppearance) -> MSADistanceRGB? {
        normalized(value).map { Self.rampColor(at: $0, appearance: appearance) }
    }

    // MARK: Ramp

    public static func background(_ appearance: MSADistanceAppearance) -> MSADistanceRGB {
        switch appearance {
        case .light: return .white
        case .dark: return MSADistanceRGB(red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255)
        }
    }

    static func rampEnd(_ appearance: MSADistanceAppearance) -> MSADistanceRGB {
        switch appearance {
        case .light: return MSADistanceRGB(red: 43.0 / 255, green: 38.0 / 255, blue: 128.0 / 255)
        case .dark: return MSADistanceRGB(red: 180.0 / 255, green: 176.0 / 255, blue: 255.0 / 255)
        }
    }

    public static func rampColor(at t: Double, appearance: MSADistanceAppearance) -> MSADistanceRGB {
        let clamped = min(max(t, 0), 1)
        let fraction = rampFloor + (1 - rampFloor) * clamped
        let start = MSADistanceOKLab(background(appearance))
        let end = MSADistanceOKLab(rampEnd(appearance))
        return start.interpolated(to: end, fraction: fraction).rgb
    }

    // MARK: Contrast

    public static func contrastRatio(_ a: MSADistanceRGB, _ b: MSADistanceRGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Black or white, whichever contrasts more with the fill. One of the two
    /// always reaches at least 4.58:1.
    public static func textColor(on fill: MSADistanceRGB) -> MSADistanceRGB {
        contrastRatio(fill, .black) >= contrastRatio(fill, .white) ? .black : .white
    }
}

/// Number formats shared by cells, AX labels, the footer and copies.
public enum MSADistanceValueFormat {
    /// Four decimals for the drawn cell (ruling U5).
    public static func cell(_ value: Double) -> String {
        if value.isNaN { return "n/a" }
        if value == .infinity { return "∞" }
        return String(format: "%.4f", value)
    }

    /// Six decimals, the TSV format of `lungfish-cli msa distance`.
    public static func full(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        return String(format: "%.6f", value)
    }

    public static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter
    }()
}
