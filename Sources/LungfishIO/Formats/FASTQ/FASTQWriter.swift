// FASTQWriter.swift - FASTQ file writer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation
import LungfishCore

/// Writer for FASTQ format files.
///
/// ## Usage
/// ```swift
/// let writer = FASTQWriter(url: outputURL)
/// try writer.open()
///
/// for record in records {
///     try writer.write(record)
/// }
///
/// try writer.close()
/// ```
///
/// Or using the convenience method:
/// ```swift
/// try FASTQWriter.write(records, to: outputURL)
/// ```
public final class FASTQWriter {

    // MARK: - Configuration

    /// Target URL for output
    public let url: URL

    /// Quality encoding for output
    public let encoding: QualityEncoding

    /// Line width for sequence wrapping (0 = no wrapping)
    public let lineWidth: Int

    /// Whether to include description in separator line
    public let includeDescriptionInSeparator: Bool

    // MARK: - State

    private var fileHandle: FileHandle?
    private var recordsWritten: Int = 0

    /// Internal write buffer to reduce syscalls. Flushed when full or on close.
    private static let bufferCapacity = 262_144 // 256 KB
    private var writeBuffer = Data()
    private var bufferCapacity: Int { Self.bufferCapacity }

    /// Optional statistics collector that piggybacks on the write pass.
    /// When set, every written record is also fed to the collector.
    /// Call `finalizeStatistics()` after closing to retrieve results.
    public var statisticsCollector: FASTQStatisticsCollector?

    // MARK: - Initialization

    /// Creates a FASTQ writer.
    ///
    /// - Parameters:
    ///   - url: Output file URL
    ///   - encoding: Quality encoding (default: Phred+33)
    ///   - lineWidth: Line width for wrapping (0 = no wrap)
    ///   - includeDescriptionInSeparator: Include header in separator line
    public init(
        url: URL,
        encoding: QualityEncoding = .phred33,
        lineWidth: Int = 0,
        includeDescriptionInSeparator: Bool = false
    ) {
        self.url = url
        self.encoding = encoding
        self.lineWidth = lineWidth
        self.includeDescriptionInSeparator = includeDescriptionInSeparator
    }

    // MARK: - File Operations

    /// Opens the file for writing.
    ///
    /// Creates the file if it doesn't exist, or truncates if it does.
    public func open() throws {
        let manager = FileManager.default

        // Create parent directory if needed
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Create or truncate file
        manager.createFile(atPath: url.path, contents: nil)

        fileHandle = try FileHandle(forWritingTo: url)
        recordsWritten = 0
        writeBuffer.removeAll(keepingCapacity: true)
    }

    /// Flushes the internal write buffer to disk.
    public func flush() throws {
        guard let handle = fileHandle, !writeBuffer.isEmpty else { return }
        try handle.write(contentsOf: writeBuffer)
        writeBuffer.removeAll(keepingCapacity: true)
    }

    /// Flushes remaining data and closes the file.
    public func close() throws {
        try flush()
        try fileHandle?.close()
        fileHandle = nil
    }

    /// Number of records written so far.
    public var count: Int { recordsWritten }

    /// Finalizes and returns the collected statistics, if a collector was attached.
    ///
    /// Call after `close()` to get the complete statistics for all written records.
    public func finalizeStatistics() -> FASTQDatasetStatistics? {
        statisticsCollector?.finalize()
    }

    // MARK: - Writing

    /// Writes a single FASTQ record.
    ///
    /// Data is buffered internally and flushed when the buffer reaches 256 KB
    /// or when `close()` / `flush()` is called.
    ///
    /// - Parameter record: The record to write
    public func write(_ record: FASTQRecord) throws {
        guard fileHandle != nil else {
            throw FASTQWriterError.fileNotOpen
        }

        let data = formatRecord(record)
        writeBuffer.append(data)
        recordsWritten += 1
        statisticsCollector?.process(record)

        if writeBuffer.count >= bufferCapacity {
            try flush()
        }
    }

    /// Writes multiple FASTQ records.
    ///
    /// - Parameter records: Array of records to write
    public func write(_ records: [FASTQRecord]) throws {
        for record in records {
            try write(record)
        }
    }

    /// Writes records from an async sequence.
    ///
    /// - Parameter records: Async sequence of records
    public func write<S: AsyncSequence>(_ records: S) async throws where S.Element == FASTQRecord {
        for try await record in records {
            try write(record)
        }
    }

    // MARK: - Formatting

    private func formatRecord(_ record: FASTQRecord) -> Data {
        var output = ""

        // Header line
        output += "@\(record.identifier)"
        if let description = record.description {
            output += " \(description)"
        }
        output += "\n"

        // Sequence line(s)
        if lineWidth > 0 {
            output += wrapLines(record.sequence, width: lineWidth)
        } else {
            output += record.sequence
        }
        output += "\n"

        // Separator line
        output += "+"
        if includeDescriptionInSeparator {
            output += record.identifier
            if let description = record.description {
                output += " \(description)"
            }
        }
        output += "\n"

        // Quality line(s)
        let qualityString = record.quality.toAscii(encoding: encoding)
        if lineWidth > 0 {
            output += wrapLines(qualityString, width: lineWidth)
        } else {
            output += qualityString
        }
        output += "\n"

        return Data(output.utf8)
    }

    private func wrapLines(_ string: String, width: Int) -> String {
        var lines: [String] = []
        var index = string.startIndex

        while index < string.endIndex {
            let end = string.index(index, offsetBy: width, limitedBy: string.endIndex) ?? string.endIndex
            lines.append(String(string[index..<end]))
            index = end
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Convenience Methods

    /// Writes records to a file in one operation.
    ///
    /// - Parameters:
    ///   - records: Array of records to write
    ///   - url: Output file URL
    ///   - encoding: Quality encoding
    public static func write(
        _ records: [FASTQRecord],
        to url: URL,
        encoding: QualityEncoding = .phred33
    ) throws {
        let writer = FASTQWriter(url: url, encoding: encoding)
        try writer.open()
        defer { try? writer.close() }
        try writer.write(records)
    }

    /// Writes records from an async sequence to a file.
    ///
    /// - Parameters:
    ///   - records: Async sequence of records
    ///   - url: Output file URL
    ///   - encoding: Quality encoding
    public static func write<S: AsyncSequence>(
        _ records: S,
        to url: URL,
        encoding: QualityEncoding = .phred33
    ) async throws where S.Element == FASTQRecord {
        let writer = FASTQWriter(url: url, encoding: encoding)
        try writer.open()
        defer { try? writer.close() }
        try await writer.write(records)
    }
}

// MARK: - FASTQWriterError

/// Errors that can occur when writing FASTQ files.
public enum FASTQWriterError: Error, LocalizedError, Sendable {

    /// Attempted to write before opening file
    case fileNotOpen

    /// Could not create output file
    case cannotCreateFile(URL)

    /// Write operation failed
    case writeFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotOpen:
            return "FASTQ file not open for writing"
        case .cannotCreateFile(let url):
            return "Cannot create FASTQ file: \(url.path)"
        case .writeFailed(let error):
            return "FASTQ write failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Record Transformation

extension FASTQRecord {

    /// Creates a new record with trimmed sequence and quality.
    ///
    /// - Parameters:
    ///   - start: Start position (0-based, inclusive)
    ///   - end: End position (exclusive, or nil for end of sequence)
    /// - Returns: Trimmed record
    public func trimmed(from start: Int = 0, to end: Int? = nil) -> FASTQRecord {
        let endPos = end ?? length
        let clampedStart = max(0, min(start, length))
        let clampedEnd = max(clampedStart, min(endPos, length))

        let startIndex = sequence.index(sequence.startIndex, offsetBy: clampedStart)
        let endIndex = sequence.index(sequence.startIndex, offsetBy: clampedEnd)
        let trimmedSequence = String(sequence[startIndex..<endIndex])

        let trimmedQuality = QualityScore(
            values: Array(quality.qualitiesIn(clampedStart..<clampedEnd)),
            encoding: quality.encoding
        )

        return FASTQRecord(
            identifier: identifier,
            description: description,
            sequence: trimmedSequence,
            quality: trimmedQuality
        )
    }

    /// Creates a new record with quality-based trimming from 3' end.
    ///
    /// - Parameters:
    ///   - threshold: Minimum quality threshold
    ///   - windowSize: Sliding window size for quality calculation
    /// - Returns: Trimmed record
    public func qualityTrimmed(threshold: UInt8 = 20, windowSize: Int = 5) -> FASTQRecord {
        let trimPos = quality.trimPosition(threshold: threshold, windowSize: windowSize)
        return trimmed(from: 0, to: trimPos)
    }

    /// Creates a reverse complement of the record.
    ///
    /// - Returns: Reverse complemented record
    public func reverseComplement() -> FASTQRecord {
        let rcSequence = TranslationEngine.reverseComplement(sequence)
        let rcQuality = QualityScore(
            values: quality.reversed(),
            encoding: quality.encoding
        )

        return FASTQRecord(
            identifier: identifier,
            description: description,
            sequence: rcSequence,
            quality: rcQuality
        )
    }
}
