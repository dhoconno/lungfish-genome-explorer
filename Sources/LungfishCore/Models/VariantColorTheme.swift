// VariantColorTheme.swift - Configurable color themes for variant rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A color expressed as RGB components (0.0–1.0).
public struct ThemeColor: Sendable, Codable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.r = Double((hex >> 16) & 0xFF) / 255.0
        self.g = Double((hex >> 8) & 0xFF) / 255.0
        self.b = Double(hex & 0xFF) / 255.0
    }
}

/// A configurable color theme for variant and genotype rendering.
///
/// Contains colors for genotype calls, variant types, and amino acid impact levels.
/// Built-in themes are available via static properties.
public struct VariantColorTheme: Sendable, Codable, Equatable {

    /// Human-readable theme name.
    public let name: String

    // MARK: - Genotype Colors

    /// Color for homozygous reference (0/0).
    public var homRef: ThemeColor
    /// Color for heterozygous (0/1).
    public var het: ThemeColor
    /// Color for homozygous alternate (1/1).
    public var homAlt: ThemeColor
    /// Color for no-call (./.).
    public var noCall: ThemeColor

    // MARK: - Variant Type Colors

    /// Color for SNP variants.
    public var snp: ThemeColor
    /// Color for insertion variants.
    public var ins: ThemeColor
    /// Color for deletion variants.
    public var del: ThemeColor
    /// Color for MNP (multi-nucleotide polymorphism) variants.
    public var mnp: ThemeColor
    /// Color for complex/other variants.
    public var complex: ThemeColor

    // MARK: - Impact Colors (Het / HomAlt pairs)

    /// Missense impact for het genotype.
    public var missenseHet: ThemeColor
    /// Missense impact for hom-alt genotype.
    public var missenseHomAlt: ThemeColor
    /// Nonsense impact for het genotype.
    public var nonsenseHet: ThemeColor
    /// Nonsense impact for hom-alt genotype.
    public var nonsenseHomAlt: ThemeColor
    /// Frameshift impact for het genotype.
    public var frameshiftHet: ThemeColor
    /// Frameshift impact for hom-alt genotype.
    public var frameshiftHomAlt: ThemeColor

    public init(name: String) {
        self = Self.modern
        // Override the name from the preset while keeping colors.
        // (Swift structs are value types, so self = modern copies everything)
    }

    // Memberwise init
    public init(
        name: String,
        homRef: ThemeColor, het: ThemeColor, homAlt: ThemeColor, noCall: ThemeColor,
        snp: ThemeColor, ins: ThemeColor, del: ThemeColor, mnp: ThemeColor, complex: ThemeColor,
        missenseHet: ThemeColor, missenseHomAlt: ThemeColor,
        nonsenseHet: ThemeColor, nonsenseHomAlt: ThemeColor,
        frameshiftHet: ThemeColor, frameshiftHomAlt: ThemeColor
    ) {
        self.name = name
        self.homRef = homRef; self.het = het; self.homAlt = homAlt; self.noCall = noCall
        self.snp = snp; self.ins = ins; self.del = del; self.mnp = mnp; self.complex = complex
        self.missenseHet = missenseHet; self.missenseHomAlt = missenseHomAlt
        self.nonsenseHet = nonsenseHet; self.nonsenseHomAlt = nonsenseHomAlt
        self.frameshiftHet = frameshiftHet; self.frameshiftHomAlt = frameshiftHomAlt
    }

    // MARK: - Built-In Themes

    /// Modern theme — refined, less saturated colors for a macOS-native look.
    public static let modern = VariantColorTheme(
        name: "Modern",
        // Genotypes
        homRef:   ThemeColor(hex: 0xD0D0D0),   // light gray
        het:      ThemeColor(hex: 0x3B82C4),   // calm blue
        homAlt:   ThemeColor(hex: 0x5B4BA8),   // deep indigo
        noCall:   ThemeColor(hex: 0xF0F0F0),   // near-white
        // Variant types
        snp:      ThemeColor(hex: 0x2D9A5C),   // emerald green
        ins:      ThemeColor(hex: 0x6B5BCC),   // blue-violet
        del:      ThemeColor(hex: 0xD44040),   // coral red
        mnp:      ThemeColor(hex: 0xCC8033),   // amber
        complex:  ThemeColor(hex: 0x7A8A99),   // slate
        // Impact — missense
        missenseHet:     ThemeColor(hex: 0xE08030),  // warm orange
        missenseHomAlt:  ThemeColor(hex: 0xC06020),  // deep orange
        // Impact — nonsense
        nonsenseHet:     ThemeColor(hex: 0xD83030),  // bright red
        nonsenseHomAlt:  ThemeColor(hex: 0xB01818),  // dark red
        // Impact — frameshift
        frameshiftHet:   ThemeColor(hex: 0x8844AA),  // muted purple
        frameshiftHomAlt: ThemeColor(hex: 0x6A2888)  // dark purple
    )

    /// Classic IGV-compatible theme.
    public static let igvClassic = VariantColorTheme(
        name: "IGV Classic",
        // Genotypes (original IGV)
        homRef:   ThemeColor(r: 200/255, g: 200/255, b: 200/255),
        het:      ThemeColor(r: 34/255,  g: 12/255,  b: 253/255),
        homAlt:   ThemeColor(r: 17/255,  g: 248/255, b: 254/255),
        noCall:   ThemeColor(r: 250/255, g: 250/255, b: 250/255),
        // Variant types (original)
        snp:      ThemeColor(r: 0.0,  g: 0.6, b: 0.2),
        ins:      ThemeColor(r: 0.5,  g: 0.0, b: 0.8),
        del:      ThemeColor(r: 0.8,  g: 0.0, b: 0.0),
        mnp:      ThemeColor(r: 0.8,  g: 0.5, b: 0.0),
        complex:  ThemeColor(r: 0.5,  g: 0.5, b: 0.5),
        // Impact
        missenseHet:     ThemeColor(r: 0.95, g: 0.4,  b: 0.1),
        missenseHomAlt:  ThemeColor(r: 0.85, g: 0.2,  b: 0.0),
        nonsenseHet:     ThemeColor(r: 0.95, g: 0.1,  b: 0.1),
        nonsenseHomAlt:  ThemeColor(r: 0.75, g: 0.0,  b: 0.0),
        frameshiftHet:   ThemeColor(r: 0.6,  g: 0.1,  b: 0.7),
        frameshiftHomAlt: ThemeColor(r: 0.45, g: 0.0,  b: 0.55)
    )

    /// High contrast theme for accessibility.
    public static let highContrast = VariantColorTheme(
        name: "High Contrast",
        // Genotypes — maximum distinction
        homRef:   ThemeColor(hex: 0xCCCCCC),
        het:      ThemeColor(hex: 0x0055DD),   // strong blue
        homAlt:   ThemeColor(hex: 0xFF6600),   // bright orange (not cyan — more distinct from blue)
        noCall:   ThemeColor(hex: 0xEEEEEE),
        // Variant types
        snp:      ThemeColor(hex: 0x009933),
        ins:      ThemeColor(hex: 0x6600CC),
        del:      ThemeColor(hex: 0xCC0000),
        mnp:      ThemeColor(hex: 0xFF8800),
        complex:  ThemeColor(hex: 0x666666),
        // Impact
        missenseHet:     ThemeColor(hex: 0xFF8800),
        missenseHomAlt:  ThemeColor(hex: 0xDD6600),
        nonsenseHet:     ThemeColor(hex: 0xFF0000),
        nonsenseHomAlt:  ThemeColor(hex: 0xCC0000),
        frameshiftHet:   ThemeColor(hex: 0x9900CC),
        frameshiftHomAlt: ThemeColor(hex: 0x6600AA)
    )

    /// All built-in themes.
    public static let allBuiltIn: [VariantColorTheme] = [modern, igvClassic, highContrast]

    /// Returns the built-in theme matching the given name, or `.modern` if not found.
    public static func named(_ name: String) -> VariantColorTheme {
        allBuiltIn.first { $0.name == name } ?? .modern
    }
}
