// QualityEncoding.swift - FASTQ quality encodings and their detection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Quality Encoding

/// Quality score encoding schemes for FASTQ files.
///
/// FASTQ files encode quality scores as ASCII characters. Different platforms
/// use different offset values:
/// - **Phred+33 (Sanger)**: ASCII 33-126 → Quality 0-93 (Illumina 1.8+)
/// - **Phred+64 (Illumina 1.3-1.7)**: ASCII 64-126 → Quality 0-62
///
/// Modern Illumina sequencers (1.8+) use Phred+33 encoding.
public enum QualityEncoding: String, CaseIterable, Codable, Sendable {

    /// Phred+33 encoding (Sanger, Illumina 1.8+)
    /// ASCII 33 (!) = quality 0
    case phred33

    /// Phred+64 encoding (Illumina 1.3-1.7)
    /// ASCII 64 (@) = quality 0
    case phred64

    /// Solexa encoding (early Solexa/Illumina)
    /// Uses different probability formula
    case solexa

    /// ASCII offset for this encoding
    public var asciiOffset: UInt8 {
        switch self {
        case .phred33:
            return 33  // '!'
        case .phred64:
            return 64  // '@'
        case .solexa:
            return 64  // '@'
        }
    }

    /// Minimum valid ASCII character for this encoding
    public var minAscii: UInt8 {
        switch self {
        case .phred33:
            return 33  // '!'
        case .phred64:
            return 64  // '@'
        case .solexa:
            return 59  // ';' (can be negative in Solexa)
        }
    }

    /// Maximum valid ASCII character for this encoding
    public var maxAscii: UInt8 {
        switch self {
        case .phred33:
            return 126  // '~'
        case .phred64:
            return 126  // '~'
        case .solexa:
            return 126  // '~'
        }
    }

    /// Maximum quality value for this encoding
    public var maxQuality: Int {
        switch self {
        case .phred33:
            return 93
        case .phred64:
            return 62
        case .solexa:
            return 62
        }
    }

    /// Display name for the encoding
    public var displayName: String {
        switch self {
        case .phred33:
            return "Phred+33 (Sanger/Illumina 1.8+)"
        case .phred64:
            return "Phred+64 (Illumina 1.3-1.7)"
        case .solexa:
            return "Solexa (deprecated)"
        }
    }
}

// MARK: - Encoding Detection

extension QualityEncoding {

    /// Detects the encoding from quality characters.
    ///
    /// Heuristic:
    /// - If any character < 59, must be Phred+33
    /// - If any character in 59-63 range with none < 64, likely Solexa
    /// - If all characters >= 64, could be Phred+64 or Phred+33 with high quality
    /// - Default to Phred+33 (most common modern format)
    ///
    /// - Parameter ascii: Sample of ASCII quality characters
    /// - Returns: Detected encoding
    public static func detect(from ascii: String) -> QualityEncoding {
        detect(fromBytes: Array(ascii.utf8))
    }

    /// The same test on raw quality bytes.
    package static func detect(fromBytes bytes: [UInt8]) -> QualityEncoding {
        guard !bytes.isEmpty else {
            return .phred33
        }

        let minByte = bytes.min() ?? 33
        let maxByte = bytes.max() ?? 33

        // Characters below 59 are only valid in Phred+33
        if minByte < 59 {
            return .phred33
        }

        // Characters in 59-63 range (;, <, =, >, ?) are valid in Solexa
        // but not in Phred+64
        if minByte >= 59 && minByte < 64 && maxByte > 74 {
            return .solexa
        }

        // If all characters are >= 64 and some are high, could be Phred+64
        // But Phred+33 is more common, so prefer it unless we see very high values
        if minByte >= 64 && maxByte > 104 {
            // Quality > 73 in Phred+33 (ASCII > 106) is unusual
            // High values suggest Phred+64 encoding
            return .phred64
        }

        // Default to modern standard
        return .phred33
    }
}

// MARK: - Legacy Phred+64 guard

extension QualityEncoding {

    /// True when the first 10,000 records of `url` look like the old Phred+64 encoding (BIO-BIN-QIN, N2).
    ///
    /// Declared by the tests-first commit of the fix, so its tests compile. It reads nothing and answers false until the
    /// fix commit that follows.
    package static func looksLikeLegacyPhred64(_ url: URL, launcher: any PortableChildLauncher) throws -> Bool {
        false
    }
}
