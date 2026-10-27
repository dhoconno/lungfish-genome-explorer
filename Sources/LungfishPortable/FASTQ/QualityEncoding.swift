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

    /// The refusal of a file in the old Phred+64 encoding (BIO-BIN-QIN, N2). Its words are what an import's operation row
    /// and an executor step's reason show.
    package struct LegacyPhred64Refusal: Error, LocalizedError, Equatable {
        package init() {}

        package var errorDescription: String? {
            "This file's quality scores look like the old Phred+64 encoding (Illumina pipeline 1.3 to 1.7). "
                + "LGE stores Phred+33 scores only. Convert the file first, for example with reformat.sh qin=64 qout=33, "
                + "then import the new file."
        }
    }

    /// True when the first 10,000 records of `url` look like the old Phred+64 encoding (BIO-BIN-QIN, N2).
    ///
    /// Every storage step tells BBTools the scores are Phred+33 (``PortableStoragePlan/qualityEncodingArguments``), so
    /// such a file would be stored 31 too high. ``detect(from:)`` is no guard, since it calls a real HiFi read Phred+64
    /// and a typical Illumina 1.5 file (bytes `B` to `h`) Phred+33. This test is true when no quality byte is below 64,
    /// none is above 105 (`i`) and the mean read length is under 400, so a modern file with a score below Q31, a score
    /// of Q73 or more, or long reads is never refused. A plain or gzip file is read through `launcher`.
    package static func looksLikeLegacyPhred64(_ url: URL, launcher: any PortableChildLauncher) throws -> Bool {
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)
        defer { reader.close() }
        /// The next line without its carriage return, nil at the end of the file.
        func next() throws -> [UInt8]? {
            guard var line = try reader.nextLine() else { return nil }
            if line.last == 0x0D { line.removeLast() }
            return line
        }
        var records = 0
        var bases = 0
        var lowest = UInt8.max
        var highest = UInt8.min
        while records < 10_000, let header = try next() {
            if header.isEmpty { continue }
            guard header.first == UInt8(ascii: "@") else { return false }
            var sequenceLength = 0
            var reachedQualities = false
            while let line = try next() {
                if line.first == UInt8(ascii: "+") {
                    reachedQualities = true
                    break
                }
                sequenceLength += line.count
            }
            guard reachedQualities else { return false }
            var qualityLength = 0
            while qualityLength < sequenceLength, let line = try next() {
                for byte in line {
                    lowest = min(lowest, byte)
                    highest = max(highest, byte)
                }
                qualityLength += line.count
            }
            // One byte below '@' or above 'i' settles it, since the answer can only stay no.
            if lowest < 64 || highest > 105 { return false }
            records += 1
            bases += sequenceLength
        }
        guard records > 0, lowest <= highest else { return false }
        return bases / records < 400
    }

    /// Throws ``LegacyPhred64Refusal`` when any of `urls` looks like the old Phred+64 encoding. A file this guard cannot
    /// read is left for the storage tool to report in its own words.
    package static func refuseLegacyPhred64(_ urls: [URL], launcher: any PortableChildLauncher) throws {
        for url in urls where (try? looksLikeLegacyPhred64(url, launcher: launcher)) == true {
            throw LegacyPhred64Refusal()
        }
    }
}
