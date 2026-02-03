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
public struct FASTQRecord: Sendable, Equatable, Identifiable {

    /// Unique identifier for the read
    public var id: String { identifier }

    /// Read identifier (from header, without '@')
    public let identifier: String

    /// Optional description (text after first space in header)
    public let description: String?

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
                    var currentSequence: String?
                    var currentSeparator: String?
                    var nonEmptyLineCount = 0

                    // Use auto-decompressing lines for gzip support
                    for try await line in url.linesAutoDecompressing() {
                        lineNumber += 1

                        guard line.count <= self.maxLineLength else {
                            throw FASTQError.lineTooLong(line: lineNumber, length: line.count)
                        }

                        // Skip empty lines
                        if line.isEmpty { continue }

                        nonEmptyLineCount += 1
                        let lineState = (nonEmptyLineCount - 1) % 4

                        switch lineState {
                        case 0:
                            // Header line
                            guard line.hasPrefix("@") else {
                                throw FASTQError.invalidHeader(line: lineNumber, content: line)
                            }
                            currentHeader = String(line.dropFirst())

                        case 1:
                            // Sequence line
                            if self.validateSequence {
                                try self.validateSequenceCharacters(line, lineNumber: lineNumber)
                            }
                            currentSequence = line

                        case 2:
                            // Separator line (+ optionally followed by header)
                            guard line.hasPrefix("+") else {
                                throw FASTQError.invalidSeparator(line: lineNumber, content: line)
                            }
                            currentSeparator = line

                        case 3:
                            // Quality line
                            guard let header = currentHeader,
                                  let sequence = currentSequence else {
                                throw FASTQError.incompleteRecord(line: lineNumber)
                            }

                            guard line.count == sequence.count else {
                                throw FASTQError.qualityLengthMismatch(
                                    line: lineNumber,
                                    sequenceLength: sequence.count,
                                    qualityLength: line.count
                                )
                            }

                            // Auto-detect encoding from first record
                            if detectedEncoding == nil {
                                detectedEncoding = QualityEncoding.detect(from: line)
                            }

                            let (identifier, description) = self.parseHeader(header)
                            let quality = QualityScore(
                                ascii: line,
                                encoding: detectedEncoding ?? .phred33
                            )

                            let record = FASTQRecord(
                                identifier: identifier,
                                description: description,
                                sequence: sequence,
                                quality: quality
                            )

                            continuation.yield(record)

                            // Reset for next record
                            currentHeader = nil
                            currentSequence = nil
                            currentSeparator = nil

                        default:
                            break
                        }
                    }

                    // Check for incomplete record at end
                    if currentHeader != nil || currentSequence != nil {
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
        var lineNumber = 0
        for try await line in url.linesAutoDecompressing() {
            if !line.isEmpty {
                lineNumber += 1
                if lineNumber % 4 == 0 {
                    count += 1
                }
            }
        }
        return count
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
        let validBases = CharacterSet(charactersIn: "ACGTUNacgtun")
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
