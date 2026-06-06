import Foundation

public struct HaplotypeColorToken: Equatable, Hashable, Codable, Sendable {
    public let canonicalIndex: Int
    public let displayName: String
    public let fillColor: AnnotationColor
    public let darkFillColor: AnnotationColor
    public let fontColor: AnnotationColor
    public let glyph: HaplotypeBlockGlyph

    public init(canonicalIndex: Int,
                displayName: String,
                fillColor: AnnotationColor,
                darkFillColor: AnnotationColor,
                fontColor: AnnotationColor,
                glyph: HaplotypeBlockGlyph) {
        self.canonicalIndex = canonicalIndex
        self.displayName = displayName
        self.fillColor = fillColor
        self.darkFillColor = darkFillColor
        self.fontColor = fontColor
        self.glyph = glyph
    }
}

public extension HaplotypeColorToken {
    /// The canonical Budde 2010 M0-M7 tokens. These indices have semantic
    /// meaning to scientists working with MCM (Mauritian Cynomolgus Macaque)
    /// MHC and must never be reordered or recolored.
    ///
    /// Index 0 is reserved for "Absent" (gap / missing call).
    static let canonicalBudde2010Tokens: [HaplotypeColorToken] = [
        HaplotypeColorToken(
            canonicalIndex: 0,
            displayName: "Absent",
            fillColor: AnnotationColor(red: 0.87, green: 0.87, blue: 0.87),
            darkFillColor: AnnotationColor(red: 0.27, green: 0.27, blue: 0.27),
            fontColor: AnnotationColor(red: 0.42, green: 0.42, blue: 0.42),
            glyph: .empty
        ),
        HaplotypeColorToken(
            canonicalIndex: 1,
            displayName: "M1",
            fillColor: AnnotationColor(hex: "#0C0000") ?? AnnotationColor(red: 0.05, green: 0, blue: 0),
            darkFillColor: AnnotationColor(hex: "#1A1A1A") ?? AnnotationColor(red: 0.1, green: 0.1, blue: 0.1),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledCircle
        ),
        HaplotypeColorToken(
            canonicalIndex: 2,
            displayName: "M2",
            fillColor: AnnotationColor(hex: "#FF0000") ?? AnnotationColor(red: 1, green: 0, blue: 0),
            darkFillColor: AnnotationColor(hex: "#FF4444") ?? AnnotationColor(red: 1, green: 0.27, blue: 0.27),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledSquare
        ),
        HaplotypeColorToken(
            canonicalIndex: 3,
            displayName: "M3",
            fillColor: AnnotationColor(hex: "#0000FF") ?? AnnotationColor(red: 0, green: 0, blue: 1),
            darkFillColor: AnnotationColor(hex: "#4488FF") ?? AnnotationColor(red: 0.27, green: 0.53, blue: 1),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledTriangle
        ),
        HaplotypeColorToken(
            canonicalIndex: 4,
            displayName: "M4",
            fillColor: AnnotationColor(hex: "#008000") ?? AnnotationColor(red: 0, green: 0.5, blue: 0),
            darkFillColor: AnnotationColor(hex: "#22AA44") ?? AnnotationColor(red: 0.13, green: 0.67, blue: 0.27),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .filledDiamond
        ),
        HaplotypeColorToken(
            canonicalIndex: 5,
            displayName: "M5",
            fillColor: AnnotationColor(hex: "#FFFF00") ?? AnnotationColor(red: 1, green: 1, blue: 0),
            darkFillColor: AnnotationColor(hex: "#DDDD00") ?? AnnotationColor(red: 0.87, green: 0.87, blue: 0),
            fontColor: AnnotationColor(hex: "#0C0000") ?? AnnotationColor(red: 0.05, green: 0, blue: 0),
            glyph: .hollowCircle
        ),
        HaplotypeColorToken(
            canonicalIndex: 6,
            displayName: "M6",
            fillColor: AnnotationColor(hex: "#808080") ?? AnnotationColor(red: 0.5, green: 0.5, blue: 0.5),
            darkFillColor: AnnotationColor(hex: "#999999") ?? AnnotationColor(red: 0.6, green: 0.6, blue: 0.6),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .hollowSquare
        ),
        HaplotypeColorToken(
            canonicalIndex: 7,
            displayName: "M7",
            fillColor: AnnotationColor(hex: "#800080") ?? AnnotationColor(red: 0.5, green: 0, blue: 0.5),
            darkFillColor: AnnotationColor(hex: "#BB44BB") ?? AnnotationColor(red: 0.73, green: 0.27, blue: 0.73),
            fontColor: AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1),
            glyph: .asterisk
        ),
    ]

    /// The full canonical palette: Budde 2010 M0-M7 plus 56 perceptually-spaced
    /// extended tokens (X1-X56) generated systematically in HSB space.
    ///
    /// Indices 0-7 are immutable canonical Budde 2010 colors with semantic
    /// meaning. Indices 8-63 are derived by sweeping 8 hue stops (45 degrees
    /// apart, offset to avoid landing on pure primaries that collide with
    /// M2/M3/M4/M5/M7) across 7 lightness/saturation tints.
    ///
    /// Total: 64 tokens.
    static let canonicalPalette: [HaplotypeColorToken] = canonicalBudde2010Tokens
        + extendedTokens(startingAtIndex: canonicalBudde2010Tokens.count,
                         count: 64 - canonicalBudde2010Tokens.count)

    static let canonicalByName: [String: Int] = [
        "M0": 0, "M1": 1, "M2": 2, "M3": 3, "M4": 4, "M5": 5, "M6": 6, "M7": 7,
        "M1A": 1, "M2A": 2, "M3A": 3, "M4A": 4, "M5A": 5, "M6A": 6, "M7A": 7,
        "M1B": 1, "M2B": 2, "M3B": 3, "M4B": 4, "M5B": 5, "M6B": 6, "M7B": 7,
        "M1DR": 1, "M2DR": 2, "M3DR": 3, "M4DR": 4, "M5DR": 5, "M6DR": 6, "M7DR": 7,
        "M1DQ": 1, "M2DQ": 2, "M3DQ": 3, "M4DQ": 4, "M5DQ": 5, "M6DQ": 6, "M7DQ": 7,
        "M1DP": 1, "M2DP": 2, "M3DP": 3, "M4DP": 4, "M5DP": 5, "M6DP": 6, "M7DP": 7,
        "M4M7DP": 4, "M5M6DP": 5,
        "-": 0, "": 0, "A1_063": 1,
    ]

    static func assigned(forName name: String) -> HaplotypeColorToken {
        if let index = canonicalByName[name] {
            return canonicalPalette[index]
        }
        if name.hasPrefix("recM") {
            return canonicalPalette[1]
        }
        let bytes: [UInt8] = Array(name.utf8)
        var hash: UInt32 = 2166136261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        // Hash across the entire palette except index 0 (reserved for absent).
        // This spreads unknown haplotype names across all 63 non-empty slots
        // instead of clustering them onto the 7 canonical M-tokens.
        let assignableCount = canonicalPalette.count - 1
        let offset = Int(hash % UInt32(assignableCount))
        return canonicalPalette[1 + offset]
    }

    /// Backward-compatible alias: the full assignable palette (M1-M7 plus
    /// extended tokens), excluding the reserved "Absent" index 0.
    ///
    /// Kept for callers that historically referenced `extendedRhesusPalette`.
    /// New callers should prefer `canonicalPalette`.
    static let extendedRhesusPalette: [HaplotypeColorToken] =
        Array(canonicalPalette.dropFirst())
}

// MARK: - Extended palette generation

private extension HaplotypeColorToken {
    /// Generates `count` perceptually-spaced tokens starting at the given
    /// canonical index. Uses an 8-hue x 7-tint sweep (56 cells) in HSB space.
    ///
    /// - The hue base is offset by 18 degrees so the first generated stop
    ///   sits between magenta and orange, avoiding visual collision with
    ///   pure-primary M2 (red), M3 (blue), M4 (green), M5 (yellow), M7
    ///   (purple).
    /// - Each row uses a different saturation/brightness pair so adjacent
    ///   tokens in the linear index order remain easy to tell apart even
    ///   without consulting the hue ring.
    /// - Glyphs cycle through `HaplotypeBlockGlyph.allCases` excluding
    ///   `.empty` so that on monochrome printouts adjacent tokens are still
    ///   distinguishable.
    static func extendedTokens(startingAtIndex startIndex: Int,
                               count: Int) -> [HaplotypeColorToken] {
        let hueStops = 8
        let huesPerCycle = hueStops
        let hueBase: Double = 18.0 / 360.0
        // Tint rows: (saturation, brightness, darkBrightness). Light fills
        // are tuned to stay legible against the cream/peach light palette;
        // dark variants brighten slightly to stay legible on Deep Ink.
        let tints: [(saturation: Double, brightness: Double, darkBrightness: Double)] = [
            (0.78, 0.72, 0.82),   // strong saturated mid
            (0.55, 0.85, 0.92),   // pastel high
            (0.92, 0.55, 0.70),   // deep saturated
            (0.40, 0.92, 0.95),   // very pale
            (0.85, 0.42, 0.62),   // dark muted
            (0.70, 0.78, 0.88),   // bright pop
            (0.60, 0.62, 0.78),   // earthy mid
        ]

        let nonEmptyGlyphs = HaplotypeBlockGlyph.allCases.filter { $0 != .empty }

        var tokens: [HaplotypeColorToken] = []
        tokens.reserveCapacity(count)
        for offset in 0..<count {
            let canonicalIndex = startIndex + offset
            // Distribute (hue, tint) so that consecutive tokens jump rows AND
            // hues to maximise local distinctness. We interleave by stepping
            // the hue by 3 stops per index (relatively prime to 8) and the
            // tint by 1 row per cycle of 8.
            let hueStepIndex = (offset * 3) % huesPerCycle
            let tintIndex = (offset / huesPerCycle) % tints.count
            let hue = (hueBase + Double(hueStepIndex) / Double(huesPerCycle))
                .truncatingRemainder(dividingBy: 1.0)
            let tint = tints[tintIndex]

            let light = AnnotationColor(
                hsb: (hue: hue, saturation: tint.saturation, brightness: tint.brightness)
            )
            let dark = AnnotationColor(
                hsb: (hue: hue, saturation: max(0.30, tint.saturation - 0.10),
                      brightness: tint.darkBrightness)
            )
            let font = preferredFontColor(against: light)
            let glyph = nonEmptyGlyphs[offset % nonEmptyGlyphs.count]
            let displayName = "X\(offset + 1)"
            tokens.append(HaplotypeColorToken(
                canonicalIndex: canonicalIndex,
                displayName: displayName,
                fillColor: light,
                darkFillColor: dark,
                fontColor: font,
                glyph: glyph
            ))
        }
        return tokens
    }

    /// Picks black or white for legible text on a colored chip. Uses
    /// relative luminance per WCAG 2.x.
    static func preferredFontColor(against color: AnnotationColor) -> AnnotationColor {
        func channel(_ c: Double) -> Double {
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
        return luminance > 0.45
            ? (AnnotationColor(hex: "#0C0000") ?? AnnotationColor(red: 0.05, green: 0, blue: 0))
            : (AnnotationColor(hex: "#FFFFFF") ?? AnnotationColor(red: 1, green: 1, blue: 1))
    }
}

private extension AnnotationColor {
    /// Builds a color from HSB. `hue` in [0, 1), saturation/brightness in
    /// [0, 1]. Equivalent to `NSColor(hue:saturation:brightness:alpha:)` but
    /// pure-Foundation so this file remains usable outside AppKit.
    init(hsb: (hue: Double, saturation: Double, brightness: Double)) {
        let h = hsb.hue.truncatingRemainder(dividingBy: 1.0)
        let s = max(0, min(1, hsb.saturation))
        let v = max(0, min(1, hsb.brightness))
        let sector = h * 6.0
        let i = floor(sector)
        let f = sector - i
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let r: Double
        let g: Double
        let b: Double
        switch Int(i) % 6 {
        case 0: r = v; g = t; b = p
        case 1: r = q; g = v; b = p
        case 2: r = p; g = v; b = t
        case 3: r = p; g = q; b = v
        case 4: r = t; g = p; b = v
        default: r = v; g = p; b = q
        }
        self.init(red: r, green: g, blue: b)
    }
}
