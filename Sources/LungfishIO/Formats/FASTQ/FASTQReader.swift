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
    /// Pull-based: a record is parsed only when the consumer asks for the next
    /// one, so a slow consumer (per-read statistics, previews) never lets the
    /// parser buffer the rest of the file. The previous producer-task design
    /// yielded into an unbounded stream buffer and grew to 20 GB on a large
    /// import (2026-08-22 OOM).
    ///
    /// - Parameter url: URL of the FASTQ file
    /// - Returns: AsyncThrowingStream of FASTQ records
    public func records(from url: URL) -> AsyncThrowingStream<FASTQRecord, Error> {
        let parser = RecordSource(reader: self, lines: url.linesAutoDecompressing())
        return AsyncThrowingStream(unfolding: {
            if Task.isCancelled { return nil }
            return try await parser.next()
        })
    }

    /// Incremental FASTQ parser driven by consumer demand.
    ///
    /// Holds the line iterator and the parse state between `next()` calls so
    /// exactly one record is materialised per call. Used serially by one
    /// stream iterator.
    private final class RecordSource: @unchecked Sendable {
        private enum ParseState {
            case header
            case sequence
            case quality
        }

        private let reader: FASTQReader
        private var lines: AsyncThrowingStream<String, Error>.AsyncIterator
        private var detectedEncoding: QualityEncoding?
        private var lineNumber = 0
        private var currentHeader: String?
        private var currentSequence = ""
        private var currentQuality = ""
        private var expectedQualityLength = 0
        private var state: ParseState = .header
        private var finished = false

        init(reader: FASTQReader, lines: AsyncThrowingStream<String, Error>) {
            self.reader = reader
            self.lines = lines.makeAsyncIterator()
            self.detectedEncoding = reader.encoding
        }

        func next() async throws -> FASTQRecord? {
            if finished { return nil }
            while let line = try await lines.next() {
                if let record = try consume(line) {
                    return record
                }
            }
            finished = true
            try checkEndOfInput()
            return nil
        }

        /// Feeds one line into the parser; returns a record when one completes.
        private func consume(_ line: String) throws -> FASTQRecord? {
            lineNumber += 1

            guard line.count <= reader.maxLineLength else {
                throw FASTQError.lineTooLong(line: lineNumber, length: line.count)
            }

            switch state {
            case .header:
                // Tolerate blank lines between records, but never inside a record.
                if line.isEmpty { return nil }
                guard line.hasPrefix("@") else {
                    throw FASTQError.invalidHeader(line: lineNumber, content: line)
                }
                currentHeader = String(line.dropFirst())
                currentSequence = ""
                currentQuality = ""
                expectedQualityLength = 0
                state = .sequence
                return nil

            case .sequence:
                // FASTQ allows wrapped sequences; consume until separator line.
                if line.hasPrefix("+") {
                    expectedQualityLength = currentSequence.count
                    currentQuality = ""
                    state = .quality
                    return nil
                }
                if reader.validateSequence {
                    do {
                        try reader.validateSequenceCharacters(line, lineNumber: lineNumber)
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
                return nil

            case .quality:
                if expectedQualityLength == 0,
                   currentQuality.isEmpty,
                   line.hasPrefix("@"),
                   let header = currentHeader {
                    // Some line readers collapse empty lines. If the quality
                    // line for a zero-length read was empty and omitted,
                    // accept it and treat this as the next record header.
                    let (identifier, description) = reader.parseHeader(header)
                    let record = FASTQRecord(
                        identifier: identifier,
                        description: description,
                        sequence: "",
                        quality: QualityScore(ascii: "", encoding: detectedEncoding ?? .phred33)
                    )

                    currentHeader = String(line.dropFirst())
                    currentSequence = ""
                    currentQuality = ""
                    expectedQualityLength = 0
                    state = .sequence
                    return record
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
                    return nil
                }

                // Auto-detect encoding from first record
                if detectedEncoding == nil {
                    detectedEncoding = QualityEncoding.detect(from: currentQuality)
                }

                let (identifier, description) = reader.parseHeader(header)
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

                // Reset for next record
                currentHeader = nil
                currentSequence = ""
                currentQuality = ""
                expectedQualityLength = 0
                state = .header
                return record
            }
        }

        private func checkEndOfInput() throws {
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
        let retainedSampleLimit = max(0, sampleLimit)
        sampleRecords.reserveCapacity(min(retainedSampleLimit, 10_000))
        var count = 0

        try forEachRecord(from: url) { record in
            if count % 2_000 == 0 {
                try Task.checkCancellation()
            }
            collector.process(record)
            if count < retainedSampleLimit {
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

    /// Computes count-only statistics without retaining records, qualities, or histograms.
    ///
    /// Use this for background workflows that only need accurate read/base counts.
    /// It intentionally omits quality, GC, median, and N50 values so long-read
    /// demultiplexing can summarize outputs without constructing per-read objects.
    public func computeSummaryStatistics(
        from url: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FASTQDatasetStatistics {
        let accumulator = FASTQCountOnlyStatisticsAccumulator()
        var lineNumber = 0
        var hasCurrentHeader = false
        var currentSequenceLength = 0
        var currentQualityLength = 0
        var currentLineLength = 0
        var currentLineFirstByte: UInt8?
        var currentLineLastByte: UInt8?
        var currentLineInvalidSequenceByte: UInt8?
        enum ParseState {
            case header
            case sequence
            case quality
        }
        var state: ParseState = .header

        func finishRecord() throws {
            accumulator.process(length: currentSequenceLength)
            if accumulator.readCount % 10_000 == 0 {
                progress?(accumulator.readCount)
                try Task.checkCancellation()
            }
        }

        func resetLine() {
            currentLineLength = 0
            currentLineFirstByte = nil
            currentLineLastByte = nil
            currentLineInvalidSequenceByte = nil
        }

        func lineDescription(firstByte: UInt8?, length: Int) -> String {
            guard let firstByte else {
                return ""
            }
            let prefix = UnicodeScalar(Int(firstByte)).map { String(Character($0)) } ?? "?"
            return "\(prefix)... (\(length) bytes)"
        }

        func validateSequenceByte(_ byte: UInt8) -> Bool {
            switch byte {
            case 65, 67, 71, 84, 85, 78, 82, 89, 83, 87, 75, 77, 66, 68, 72, 86,
                 97, 99, 103, 116, 117, 110, 114, 121, 115, 119, 107, 109, 98, 100, 104, 118:
                return true
            default:
                return false
            }
        }

        func finishLine() throws {
            lineNumber += 1
            if lineNumber % 10_000 == 0 {
                try Task.checkCancellation()
            }

            let lineLength = currentLineLastByte == 13
                ? max(0, currentLineLength - 1)
                : currentLineLength

            guard lineLength <= self.maxLineLength else {
                throw FASTQError.lineTooLong(line: lineNumber, length: lineLength)
            }

            switch state {
            case .header:
                if lineLength == 0 { return }
                guard currentLineFirstByte == 64 else {
                    throw FASTQError.invalidHeader(
                        line: lineNumber,
                        content: lineDescription(firstByte: currentLineFirstByte, length: lineLength)
                    )
                }
                hasCurrentHeader = true
                currentSequenceLength = 0
                currentQualityLength = 0
                state = .sequence

            case .sequence:
                if currentLineFirstByte == 43 {
                    currentQualityLength = 0
                    state = .quality
                    return
                }
                if let invalidByte = currentLineInvalidSequenceByte {
                    let scalar = UnicodeScalar(Int(invalidByte)).map { String(Character($0)) } ?? "?"
                    if currentSequenceLength > 0 {
                        throw FASTQError.invalidSeparator(
                            line: lineNumber,
                            content: lineDescription(firstByte: currentLineFirstByte, length: lineLength)
                        )
                    }
                    throw FASTQError.invalidSequenceCharacter(line: lineNumber, character: scalar)
                }
                currentSequenceLength += lineLength

            case .quality:
                if currentSequenceLength == 0,
                   currentQualityLength == 0,
                   currentLineFirstByte == 64,
                   hasCurrentHeader {
                    try finishRecord()

                    hasCurrentHeader = true
                    currentSequenceLength = 0
                    currentQualityLength = 0
                    state = .sequence
                    return
                }

                guard hasCurrentHeader else {
                    throw FASTQError.incompleteRecord(line: lineNumber)
                }

                currentQualityLength += lineLength
                if currentQualityLength > currentSequenceLength {
                    throw FASTQError.qualityLengthMismatch(
                        line: lineNumber,
                        sequenceLength: currentSequenceLength,
                        qualityLength: currentQualityLength
                    )
                }

                guard currentQualityLength == currentSequenceLength else {
                    return
                }

                try finishRecord()
                hasCurrentHeader = false
                currentSequenceLength = 0
                currentQualityLength = 0
                state = .header
            }
        }

        try url.forEachChunkAutoDecompressing { chunk in
            for byte in chunk {
                if byte == 10 {
                    try finishLine()
                    resetLine()
                    continue
                }

                if currentLineLength == 0 {
                    currentLineFirstByte = byte
                }
                currentLineLastByte = byte

                if self.validateSequence,
                   state == .sequence,
                   currentLineFirstByte != 43,
                   byte != 13,
                   currentLineInvalidSequenceByte == nil,
                   !validateSequenceByte(byte) {
                    currentLineInvalidSequenceByte = byte
                }

                currentLineLength += 1
            }
        }

        if currentLineLength > 0 {
            try finishLine()
            resetLine()
        }

        if state != .header || hasCurrentHeader {
            throw FASTQError.unexpectedEndOfFile
        }

        try Task.checkCancellation()
        progress?(accumulator.readCount)
        return accumulator.finalize()
    }

    private func forEachRecord(
        from url: URL,
        _ body: (FASTQRecord) throws -> Void
    ) throws {
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

        try url.forEachLineAutoDecompressing { line in
            lineNumber += 1
            if lineNumber % 10_000 == 0 {
                try Task.checkCancellation()
            }

            guard line.count <= self.maxLineLength else {
                throw FASTQError.lineTooLong(line: lineNumber, length: line.count)
            }

            switch state {
            case .header:
                // Tolerate blank lines between records, but never inside a record.
                if line.isEmpty { return }
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
                    return
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
                    try body(record)

                    currentHeader = String(line.dropFirst())
                    currentSequence = ""
                    currentQuality = ""
                    expectedQualityLength = 0
                    state = .sequence
                    return
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
                    return
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

                try body(record)

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
    }

    // MARK: - Helpers

    private func parseHeader(_ header: String) -> (identifier: String, description: String?) {
        let trimmedHeader = header.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmedHeader.firstIndex(where: isHeaderWhitespace) else {
            return (trimmedHeader, nil)
        }

        let identifier = String(trimmedHeader[..<separator])
        guard let descriptionStart = trimmedHeader[separator...].firstIndex(where: { !isHeaderWhitespace($0) }) else {
            return (identifier, nil)
        }

        return (identifier, String(trimmedHeader[descriptionStart...]))
    }

    private func isHeaderWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
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

private final class FASTQCountOnlyStatisticsAccumulator {
    private(set) var readCount = 0
    private var baseCount: Int64 = 0
    private var minReadLength = Int.max
    private var maxReadLength = 0

    func process(length: Int) {
        readCount += 1
        baseCount += Int64(length)
        minReadLength = min(minReadLength, length)
        maxReadLength = max(maxReadLength, length)
    }

    func finalize() -> FASTQDatasetStatistics {
        guard readCount > 0 else {
            return .empty
        }

        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: Double(baseCount) / Double(readCount),
            minReadLength: minReadLength == Int.max ? 0 : minReadLength,
            maxReadLength: maxReadLength,
            medianReadLength: 0,
            n50ReadLength: 0,
            meanQuality: 0,
            q20Percentage: 0,
            q30Percentage: 0,
            gcContent: 0,
            readLengthHistogram: [:],
            qualityScoreHistogram: [:],
            perPositionQuality: []
        )
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
