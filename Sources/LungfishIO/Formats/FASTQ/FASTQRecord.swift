// FASTQRecord.swift - A single read record from a FASTQ file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - FASTQRecord

/// A single read record from a FASTQ file.
///
/// FASTQ format consists of four lines per record:
/// 1. Header line starting with '@'
/// 2. Sequence line
/// 3. Separator line starting with '+' (optionally followed by header)
/// 4. Quality line (ASCII-encoded)
///
/// ## Example
/// ```
/// @SRR001666.1 071112_SLXA-EAS1_s_7:5:1:817:345 length=72
/// GGGTGATGGCCGCTGCCGATGGCGTCAAATCCCACCAAGTTACCCTTAACAACTTAAGGGTTTTCAAATAGA
/// +
/// IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII9IG9ICIIIIIIIIIIIIIIIIIIIIDIIIIIII>IIIIII
/// ```
public struct FASTQRecord: SequenceRecord, Equatable, Identifiable {

    /// Unique identifier for the read
    public var id: String { identifier }

    /// Read identifier (from header, without '@')
    public let identifier: String

    /// Optional description (text after first space in header)
    public let description: String?

    /// Protocol conformance: maps to `description`
    public var recordDescription: String? { description }

    /// The DNA/RNA sequence
    public let sequence: String

    /// Quality scores for each base
    public let quality: QualityScore

    /// Read length
    public var length: Int { sequence.count }

    /// Read pair information (parsed from identifier if present)
    public var readPair: ReadPair? {
        ReadPair.parse(from: identifier)
    }

    /// Creates a FASTQ record.
    ///
    /// - Parameters:
    ///   - identifier: Read identifier
    ///   - description: Optional description
    ///   - sequence: DNA/RNA sequence
    ///   - quality: Quality scores
    public init(
        identifier: String,
        description: String? = nil,
        sequence: String,
        quality: QualityScore
    ) {
        self.identifier = identifier
        self.description = description
        self.sequence = sequence
        self.quality = quality
    }

    /// Creates a FASTQ record from raw strings.
    ///
    /// - Parameters:
    ///   - identifier: Read identifier
    ///   - description: Optional description
    ///   - sequence: DNA/RNA sequence
    ///   - qualityString: ASCII quality string
    ///   - encoding: Quality encoding
    public init(
        identifier: String,
        description: String? = nil,
        sequence: String,
        qualityString: String,
        encoding: QualityEncoding = .phred33
    ) {
        self.identifier = identifier
        self.description = description
        self.sequence = sequence
        self.quality = QualityScore(ascii: qualityString, encoding: encoding)
    }
}
