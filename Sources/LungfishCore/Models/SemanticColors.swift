// SemanticColors.swift - Centralized semantic color definitions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Centralized semantic color definitions for the Lungfish application.
///
/// All UI components should reference these canonical colors instead of
/// defining their own RGB literals. This eliminates the drift that occurs
/// when base colors or status colors are duplicated across files.
///
/// ## DNA Base Colors
///
/// The base colors follow the **IGV standard** (IGV's `SequenceTrack.java`):
///
/// | Base | Color       | RGB                  | Hex      |
/// |------|-------------|----------------------|----------|
/// | A    | Green       | (0.0, 0.8, 0.0)     | #00CC00  |
/// | T    | Red         | (0.8, 0.0, 0.0)     | #CC0000  |
/// | G    | Orange/Gold | (1.0, 0.7, 0.0)     | #FFB300  |
/// | C    | Blue        | (0.0, 0.0, 0.8)     | #0000CC  |
/// | N    | Gray        | (0.53, 0.53, 0.53)  | #888888  |
/// | U    | Red (=T)    | (0.8, 0.0, 0.0)     | #CC0000  |
///
/// These are mid-saturation colors that read well on both light and dark
/// backgrounds without overpowering surrounding UI elements.
///
/// ## Status Colors
///
/// App-owned adapters may map status colors to platform system colors.
///
/// ## Quality Score Colors
///
/// Quality thresholds follow standard Phred conventions:
/// - Q >= 30: High quality (green)
/// - Q 20-29: Medium quality (yellow)
/// - Q 10-19: Low quality (orange)
/// - Q < 10:  Very low quality (red)
///
/// ## Usage
///
/// ```swift
/// // DNA bases
/// let color = SemanticColors.DNA.color(for: "A")
///
/// // Status indicators
/// let status = SemanticColors.Status.success
///
/// // Quality overlays
/// let qColor = SemanticColors.Quality.color(for: phredScore)
/// ```
public enum SemanticColors: Sendable {

    // MARK: - DNA Base Colors

    /// Standard IGV-convention DNA base colors.
    ///
    /// These are the canonical color definitions used throughout the
    /// application for nucleotide rendering. `ReadTrackRenderer`,
    /// `BaseColors`, `FASTQPalette`, and `SequenceAppearance.default`
    /// should all derive from these values.
    public enum DNA: Sendable {

        /// Adenine -- green (#00CC00).
        public static let baseA = HexColor(red: 0.0, green: 0.8, blue: 0.0)

        /// Thymine -- red (#CC0000).
        public static let baseT = HexColor(red: 0.8, green: 0.0, blue: 0.0)

        /// Guanine -- orange/gold (#FFB300).
        public static let baseG = HexColor(red: 1.0, green: 0.7, blue: 0.0)

        /// Cytosine -- blue (#0000CC).
        public static let baseC = HexColor(red: 0.0, green: 0.0, blue: 0.8)

        /// Unknown/ambiguous base -- gray (#888888).
        public static let baseN = HexColor(red: 136.0 / 255.0, green: 136.0 / 255.0, blue: 136.0 / 255.0)

        /// Uracil (RNA) -- same as thymine.
        public static let baseU = baseT

        /// Returns the canonical color for a given base character.
        ///
        /// Handles both upper- and lowercase input. Returns `baseN` for
        /// unrecognized characters.
        ///
        /// - Parameter base: A nucleotide character (A, T, G, C, U, N).
        /// - Returns: The corresponding color value.
        public static func color(for base: Character) -> HexColor {
            switch base {
            case "A", "a": return baseA
            case "T", "t": return baseT
            case "G", "g": return baseG
            case "C", "c": return baseC
            case "U", "u": return baseU
            case "N", "n": return baseN
            default:       return baseN
            }
        }

        /// Pre-built dictionary mapping base characters to colors.
        ///
        /// Useful for tight rendering loops where dictionary lookup is
        /// preferable to a switch statement.
        public static let colorMap: [Character: HexColor] = [
            "A": baseA, "a": baseA,
            "T": baseT, "t": baseT,
            "C": baseC, "c": baseC,
            "G": baseG, "g": baseG,
            "U": baseU, "u": baseU,
            "N": baseN, "n": baseN,
        ]

        /// The default hex strings for `SequenceAppearance`.
        ///
        /// These map to the same RGB values as the color properties above,
        /// expressed as hex for Codable persistence.
        public static let defaultHexColors: [String: String] = [
            "A": "#00CC00",
            "T": "#CC0000",
            "G": "#FFB300",
            "C": "#0000CC",
            "N": "#888888",
            "U": "#CC0000",
        ]
    }

    // MARK: - Status Colors

    /// Semantic status indicator colors.
    ///
    /// These are stable fallback values. App-owned adapters can resolve them
    /// to platform dynamic colors.
    public enum Status: Sendable {

        /// Operation succeeded, item passed validation.
        public static let success = HexColor(red: 52.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0)

        /// Operation failed, item rejected.
        public static let failure = HexColor(red: 255.0 / 255.0, green: 59.0 / 255.0, blue: 48.0 / 255.0)

        /// Non-critical issue, needs attention.
        public static let warning = HexColor(red: 255.0 / 255.0, green: 149.0 / 255.0, blue: 0.0)

        /// Informational, neutral emphasis.
        public static let info = HexColor(red: 0.0, green: 122.0 / 255.0, blue: 255.0 / 255.0)
    }

    // MARK: - Quality Score Colors

    /// Phred quality score visualization colors.
    ///
    /// Follows the standard Q-score thresholds used in FASTQ analysis.
    public enum Quality: Sendable {

        /// Q >= 30 -- high quality.
        public static let high = SemanticColors.Status.success

        /// Q 20-29 -- medium quality.
        public static let medium = HexColor(red: 255.0 / 255.0, green: 204.0 / 255.0, blue: 0.0)

        /// Q 10-19 -- low quality.
        public static let low = SemanticColors.Status.warning

        /// Q < 10 -- very low quality.
        public static let veryLow = SemanticColors.Status.failure

        /// Returns the appropriate color for a Phred quality score.
        ///
        /// - Parameter score: The Phred quality score (integer).
        /// - Returns: A quality-tier color value.
        public static func color(for score: Int) -> HexColor {
            if score >= 30 { return high }
            if score >= 20 { return medium }
            if score >= 10 { return low }
            return veryLow
        }
    }

    // MARK: - Annotation Type Colors

    /// Standard colors for genomic annotation feature types.
    ///
    /// These follow common genome browser conventions (UCSC, Ensembl).
    public enum Annotation: Sendable {

        /// Gene features.
        public static let gene = HexColor(red: 0.2, green: 0.6, blue: 0.2)

        /// Coding sequence (CDS) features.
        public static let cds = HexColor(red: 0.2, green: 0.4, blue: 0.8)

        /// Exon features.
        public static let exon = HexColor(red: 0.6, green: 0.3, blue: 0.8)

        /// mRNA features.
        public static let mRNA = HexColor(red: 0.8, green: 0.4, blue: 0.2)

        /// Transcript features.
        public static let transcript = HexColor(red: 0.7, green: 0.5, blue: 0.3)

        /// Miscellaneous features.
        public static let miscFeature = HexColor(red: 0.5, green: 0.5, blue: 0.5)

        /// Region features.
        public static let region = HexColor(red: 0.4, green: 0.7, blue: 0.7)

        /// Primer features.
        public static let primer = HexColor(red: 0.2, green: 0.8, blue: 0.2)

        /// Restriction site features.
        public static let restrictionSite = HexColor(red: 0.8, green: 0.2, blue: 0.2)
    }
}
