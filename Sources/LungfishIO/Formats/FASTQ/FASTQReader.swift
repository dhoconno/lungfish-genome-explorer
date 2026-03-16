// FASTQReader.swift - FASTQ file parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

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

// MARK: - ReadPair

/// Information about paired-end read relationships.
public struct ReadPair: Sendable, Equatable {

    /// The pair identifier (shared between read 1 and read 2)
    public let pairId: String

    /// Read number in pair (1 or 2)
    public let readNumber: Int

    /// Parses pair information from a read identifier.
    ///
    /// Supports common formats:
    /// - Illumina: `@INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y 1:N:0:SAMPLE`
    /// - Older: `@READ_ID/1` or `@READ_ID/2`
    ///
    /// - Parameter identifier: Read identifier
    /// - Returns: Pair information, or nil if not paired
    public static func parse(from identifier: String) -> ReadPair? {
        // Check for /1 or /2 suffix
        if identifier.hasSuffix("/1") {
            let pairId = String(identifier.dropLast(2))
            return ReadPair(pairId: pairId, readNumber: 1)
        }
        if identifier.hasSuffix("/2") {
            let pairId = String(identifier.dropLast(2))
            return ReadPair(pairId: pairId, readNumber: 2)
        }

        // Check for Illumina format with space separator
        // @INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y 1:N:0:SAMPLE
        if let spaceIndex = identifier.firstIndex(of: " ") {
            let afterSpace = identifier[identifier.index(after: spaceIndex)...]
            if afterSpace.hasPrefix("1:") {
                return ReadPair(pairId: String(identifier[..<spaceIndex]), readNumber: 1)
            }
            if afterSpace.hasPrefix("2:") {
                return ReadPair(pairId: String(identifier[..<spaceIndex]), readNumber: 2)
            }
        }

        return nil
    }
}

// MARK: - FASTQReader

/// Async streaming reader for FASTQ files.
///
/// Supports:
/// - Standard FASTQ format
/// - Multi-line sequences (wrapping)
/// - Automatic quality encoding detection
/// - Compressed files (.gz) via automatic decompression
///
/// ## Usage
/// ```swift
/// let reader = FASTQReader()
/// for try await record in reader.records(from: url) {
///     print(record.identifier)
///     print("Length: \(record.length)")
///     print("Mean Q: \(record.quality.meanQuality)")
/// }
/// ```
public final class FASTQReader: Sendable {

    // MARK: - Configuration

    /// Quality encoding to use (nil = auto-detect)
    public let encoding: QualityEncoding?

    /// Whether to validate sequence characters
    public let validateSequence: Bool

    /// Maximum line length before treating as error
    public let maxLineLength: Int

    // MARK: - Initialization

    /// Creates a FASTQ reader.
    ///
    /// - Parameters:
    ///   - encoding: Quality encoding (nil for auto-detection)
    ///   - validateSequence: Whether to validate sequence characters
    ///   - maxLineLength: Maximum line length
    public init(
        encoding: QualityEncoding? = nil,
        validateSequence: Bool = true,
        maxLineLength: Int = 1_000_000
    ) {
        self.encoding = encoding
        self.validateSequence = validateSequence
        self.maxLineLength = maxLineLength
    }

    // MARK: - Reading

    /// Returns an async stream of FASTQ records from a file.
    ///
    /// Automatically handles gzip-compressed files (.gz extension).
    ///
    /// - Parameter url: URL of the FASTQ file
    /// - Returns: AsyncThrowingStream of FASTQ records
    public func records(from url: URL) -> AsyncThrowingStream<FASTQRecord, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var detectedEncoding = self.encoding
                    var lineNumber = 0
                    var currentHeader: String?
                    var currentSequence = ""
                    var currentQuality = ""
                    var expectedQualityLength = 0
                    enum ParseState {
                        case header
                        case sequence
                        case quality
                    }
                    var state: ParseState = .header

                    // Use auto-decompressing lines for gzip support
                    for try await line in url.linesAutoDecompressing() {
                        lineNumber += 1

                        guard line.count <= self.maxLineLength else {
                            throw FASTQError.lineTooLong(line: lineNumber, length: line.count)
                        }

                        switch state {
                        case .header:
                            // Tolerate blank lines between records, but never inside a record.
                            if line.isEmpty { continue }
                            guard line.hasPrefix("@") else {
                                throw FASTQError.invalidHeader(line: lineNumber, content: line)
                            }
                            currentHeader = String(line.dropFirst())
                            currentSequence = ""
                            currentQuality = ""
                            expectedQualityLength = 0
                            state = .sequence

                        case .sequence:
                            // FASTQ allows wrapped sequences; consume until separator line.
                            if line.hasPrefix("+") {
                                expectedQualityLength = currentSequence.count
                                currentQuality = ""
                                state = .quality
                                continue
                            }
                            if self.validateSequence {
                                do {
                                    try self.validateSequenceCharacters(line, lineNumber: lineNumber)
                                } catch let error as FASTQError {
                                    // If sequence content has already started, treat a
                                    // non-sequence line as a likely malformed separator.
                                    if case .invalidSequenceCharacter = error, !currentSequence.isEmpty {
                                        throw FASTQError.invalidSeparator(line: lineNumber, content: line)
                                    }
                                    throw error
                                }
                            }
                            currentSequence += line

                        case .quality:
                            if expectedQualityLength == 0,
                               currentQuality.isEmpty,
                               line.hasPrefix("@"),
                               let header = currentHeader {
                                // Some line readers collapse empty lines. If the quality
                                // line for a zero-length read was empty and omitted,
                                // accept it and treat this as the next record header.
                                let (identifier, description) = self.parseHeader(header)
                                let record = FASTQRecord(
                                    identifier: identifier,
                                    description: description,
                                    sequence: "",
                                    quality: QualityScore(ascii: "", encoding: detectedEncoding ?? .phred33)
                                )
                                continuation.yield(record)

                                currentHeader = String(line.dropFirst())
                                currentSequence = ""
                                currentQuality = ""
                                expectedQualityLength = 0
                                state = .sequence
                                continue
                            }

                            // Quality may be wrapped. Consume until total quality length
                            // matches sequence length. Even for empty reads, a quality
                            // line must be present (it may be empty).
                            currentQuality += line

                            guard let header = currentHeader,
                                  !currentSequence.isEmpty || expectedQualityLength == 0 else {
                                throw FASTQError.incompleteRecord(line: lineNumber)
                            }

                            if currentQuality.count > expectedQualityLength {
                                throw FASTQError.qualityLengthMismatch(
                                    line: lineNumber,
                                    sequenceLength: expectedQualityLength,
                                    qualityLength: currentQuality.count
                                )
                            }

                            guard currentQuality.count == expectedQualityLength else {
                                // Continue reading wrapped quality lines.
                                continue
                            }

                            // Auto-detect encoding from first record
                            if detectedEncoding == nil {
                                detectedEncoding = QualityEncoding.detect(from: currentQuality)
                            }

                            let (identifier, description) = self.parseHeader(header)
                            let quality = QualityScore(
                                ascii: currentQuality,
                                encoding: detectedEncoding ?? .phred33
                            )

                            let record = FASTQRecord(
                                identifier: identifier,
                                description: description,
                                sequence: currentSequence,
                                quality: quality
                            )

                            continuation.yield(record)

                            // Reset for next record
                            currentHeader = nil
                            currentSequence = ""
                            currentQuality = ""
                            expectedQualityLength = 0
                            state = .header
                        }
                    }

                    // Check for incomplete record at end
                    if state == .quality, currentHeader != nil, currentQuality.count < expectedQualityLength {
                        throw FASTQError.qualityLengthMismatch(
                            line: lineNumber,
                            sequenceLength: expectedQualityLength,
                            qualityLength: currentQuality.count
                        )
                    }
                    if state != .header || currentHeader != nil {
                        throw FASTQError.unexpectedEndOfFile
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reads all records from a file into memory.
    ///
    /// Automatically handles gzip-compressed files (.gz extension).
    ///
    /// - Parameter url: URL of the FASTQ file
    /// - Returns: Array of FASTQ records
    public func readAll(from url: URL) async throws -> [FASTQRecord] {
        var results: [FASTQRecord] = []
        for try await record in records(from: url) {
            results.append(record)
        }
        return results
    }

    /// Counts records in a file without loading sequences.
    ///
    /// Automatically handles gzip-compressed files (.gz extension).
    ///
    /// - Parameter url: URL of the FASTQ file
    /// - Returns: Number of records
    public func countRecords(in url: URL) async throws -> Int {
        var count = 0
        for try await _ in records(from: url) {
            count += 1
            if count % 10_000 == 0 {
                try Task.checkCancellation()
            }
        }
        return count
    }

    // MARK: - Streaming Statistics

    /// Computes comprehensive statistics by streaming through the entire FASTQ file.
    ///
    /// Processes every record for accurate statistics but only retains the first
    /// `sampleLimit` records for display in a table view. This allows computing
    /// statistics over millions of reads without exhausting memory.
    ///
    /// - Parameters:
    ///   - url: URL of the FASTQ file (supports .gz)
    ///   - sampleLimit: Maximum number of records to retain (default 10,000)
    ///   - progress: Optional callback reporting the number of records processed so far
    /// - Returns: Tuple of computed statistics and a sample of records for display
    public func computeStatistics(
        from url: URL,
        sampleLimit: Int = 10_000,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (statistics: FASTQDatasetStatistics, sampleRecords: [FASTQRecord]) {
        let collector = FASTQStatisticsCollector()
        var sampleRecords: [FASTQRecord] = []
        sampleRecords.reserveCapacity(min(sampleLimit, 10_000))
        var count = 0

        for try await record in records(from: url) {
            if count % 2_000 == 0 {
                try Task.checkCancellation()
            }
            collector.process(record)
            if count < sampleLimit {
                sampleRecords.append(record)
            }
            count += 1
            if count % 10_000 == 0 {
                progress?(count)
                try Task.checkCancellation()
            }
        }

        try Task.checkCancellation()
        progress?(count)
        return (collector.finalize(), sampleRecords)
    }

    // MARK: - Helpers

    private func parseHeader(_ header: String) -> (identifier: String, description: String?) {
        if let spaceIndex = header.firstIndex(of: " ") {
            let identifier = String(header[..<spaceIndex])
            let description = String(header[header.index(after: spaceIndex)...])
            return (identifier, description.isEmpty ? nil : description)
        }
        return (header, nil)
    }

    private func validateSequenceCharacters(_ sequence: String, lineNumber: Int) throws {
        // Accept all IUPAC nucleotide codes (R, Y, S, W, K, M, B, D, H, V)
        // in addition to standard bases, since consensus callers and some
        // instruments emit ambiguity codes.
        let validBases = CharacterSet(charactersIn: "ACGTUNRYSWKMBDHVacgtunryswkmbdhv")
        for char in sequence.unicodeScalars {
            if !validBases.contains(char) {
                throw FASTQError.invalidSequenceCharacter(
                    line: lineNumber,
                    character: String(char)
                )
            }
        }
    }
}

// MARK: - FASTQError

/// Errors that can occur when parsing FASTQ files.
public enum FASTQError: Error, LocalizedError, Sendable {

    /// Header line doesn't start with '@'
    case invalidHeader(line: Int, content: String)

    /// Separator line doesn't start with '+'
    case invalidSeparator(line: Int, content: String)

    /// Quality line length doesn't match sequence length
    case qualityLengthMismatch(line: Int, sequenceLength: Int, qualityLength: Int)

    /// Record is incomplete (missing fields)
    case incompleteRecord(line: Int)

    /// Invalid character in sequence
    case invalidSequenceCharacter(line: Int, character: String)

    /// Line exceeds maximum length
    case lineTooLong(line: Int, length: Int)

    /// Unexpected end of file
    case unexpectedEndOfFile

    /// File not found
    case fileNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader(let line, let content):
            return "Invalid FASTQ header at line \(line): '\(content.prefix(50))'"
        case .invalidSeparator(let line, let content):
            return "Invalid separator at line \(line): '\(content.prefix(50))'"
        case .qualityLengthMismatch(let line, let seqLen, let qualLen):
            return "Quality length (\(qualLen)) doesn't match sequence length (\(seqLen)) at line \(line)"
        case .incompleteRecord(let line):
            return "Incomplete FASTQ record at line \(line)"
        case .invalidSequenceCharacter(let line, let char):
            return "Invalid sequence character '\(char)' at line \(line)"
        case .lineTooLong(let line, let length):
            return "Line \(line) exceeds maximum length (\(length) characters)"
        case .unexpectedEndOfFile:
            return "Unexpected end of file (incomplete record)"
        case .fileNotFound(let url):
            return "FASTQ file not found: \(url.path)"
        }
    }
}

// MARK: - Statistics

/// Statistics for a collection of FASTQ records.
public struct FASTQStatistics: Sendable {

    /// Total number of reads
    public let readCount: Int

    /// Total number of bases
    public let baseCount: Int

    /// Mean read length
    public let meanReadLength: Double

    /// Minimum read length
    public let minReadLength: Int

    /// Maximum read length
    public let maxReadLength: Int

    /// Mean quality score
    public let meanQuality: Double

    /// Percentage of bases with Q >= 20
    public let q20Percentage: Double

    /// Percentage of bases with Q >= 30
    public let q30Percentage: Double

    /// GC content percentage
    public let gcContent: Double

    /// Computes statistics from FASTQ records.
    ///
    /// - Parameter records: Array of FASTQ records
    public init(records: [FASTQRecord]) {
        self.readCount = records.count

        if records.isEmpty {
            self.baseCount = 0
            self.meanReadLength = 0
            self.minReadLength = 0
            self.maxReadLength = 0
            self.meanQuality = 0
            self.q20Percentage = 0
            self.q30Percentage = 0
            self.gcContent = 0
            return
        }

        let lengths = records.map { $0.length }
        self.baseCount = lengths.reduce(0, +)
        self.meanReadLength = Double(baseCount) / Double(readCount)
        self.minReadLength = lengths.min() ?? 0
        self.maxReadLength = lengths.max() ?? 0

        // Quality statistics
        let qualitySum = records.reduce(0.0) { $0 + $1.quality.meanQuality }
        self.meanQuality = qualitySum / Double(readCount)

        var totalBases = 0
        var q20Bases = 0
        var q30Bases = 0
        var gcBases = 0

        for record in records {
            totalBases += record.length
            for (i, char) in record.sequence.uppercased().enumerated() {
                let qual = record.quality.qualityAt(i)
                if qual >= 20 { q20Bases += 1 }
                if qual >= 30 { q30Bases += 1 }
                if char == "G" || char == "C" { gcBases += 1 }
            }
        }

        self.q20Percentage = totalBases > 0 ? Double(q20Bases) / Double(totalBases) * 100 : 0
        self.q30Percentage = totalBases > 0 ? Double(q30Bases) / Double(totalBases) * 100 : 0
        self.gcContent = totalBases > 0 ? Double(gcBases) / Double(totalBases) * 100 : 0
    }
}
