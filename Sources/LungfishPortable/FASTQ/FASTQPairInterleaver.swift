// FASTQPairInterleaver.swift - The portable core of the pair interleaver, its errors, record reads and count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Streams a paired R1/R2 FASTQ into one interleaved FASTQ without any
/// external tool, and counts FASTQ records for import integrity checks.
///
/// A paired import that skips storage optimization used to keep only the R1
/// file while its metadata claimed an interleaved pair (data loss). This type
/// writes the layout the clumpify path produces: each R1 record immediately
/// followed by its R2 mate, with every line copied byte for byte. It refuses
/// mismatched mate counts instead of silently truncating either file.
public enum FASTQPairInterleaver {

    public enum InterleaveError: Error, LocalizedError, Equatable {
        case malformedRecord(file: String, recordNumber: Int, reason: String)
        case mateCountMismatch(r1File: String, r1Records: Int, r2File: String, r2Records: Int)
        case mateNameMismatch(recordNumber: Int, r1File: String, r1Name: String, r2File: String, r2Name: String)
        case recordCountMismatch(expected: Int, actual: Int)
        case unreadableInput(file: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .malformedRecord(let file, let recordNumber, let reason):
                return "Malformed FASTQ record \(recordNumber) in \(file): \(reason)"
            case .mateCountMismatch(let r1File, let r1Records, let r2File, let r2Records):
                return "Paired FASTQ mates do not match: \(r1File) has \(r1Records) reads but \(r2File) has \(r2Records). Nothing was imported."
            case .mateNameMismatch(let recordNumber, let r1File, let r1Name, let r2File, let r2Name):
                return "Paired FASTQ mates are out of step at record \(recordNumber): \(r1File) has '\(r1Name)' but \(r2File) has '\(r2Name)'. The two files do not list the same fragments in the same order, so nothing was written."
            case .recordCountMismatch(let expected, let actual):
                return "Paired import integrity check failed: expected \(expected) interleaved reads (R1 + R2) but the output holds \(actual). Nothing was imported."
            case .unreadableInput(let file, let reason):
                return "Cannot read \(file): \(reason)"
            }
        }
    }
}

extension FASTQPairInterleaver {

    /// The header line without its leading `@`, as the classifier expects.
    package static func headerText(_ line: [UInt8]) -> String {
        String(decoding: line.dropFirst(), as: UTF8.self)
    }

    /// Counts four-line FASTQ records in a plain or gzip-compressed file.
    ///
    /// Throws when the line count is not a multiple of four, which is the
    /// signature of a truncated write.
    ///
    /// Polls for a cancel at every chunk. A cancelled caller gets
    /// `CancellationError` at the next chunk, and `close()` stops and reaps
    /// the `gzip -dc` child.
    package static func countRecords(in url: URL, launcher: any PortableChildLauncher) throws -> Int {
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)
        defer { reader.close() }
        var lines = 0
        var lastByte: UInt8 = 0x0A
        var sawBytes = false
        while let chunk = try reader.readChunk() {
            try Task.checkCancellation()
            if chunk.isEmpty { continue }
            sawBytes = true
            lines += newlineCount(in: chunk)
            lastByte = chunk[chunk.count - 1]
        }
        if sawBytes && lastByte != 0x0A { lines += 1 }
        guard lines % 4 == 0 else {
            throw InterleaveError.malformedRecord(
                file: url.lastPathComponent,
                recordNumber: lines / 4 + 1,
                reason: "file has \(lines) lines, which is not a whole number of four-line FASTQ records"
            )
        }
        return lines / 4
    }

    /// Newlines in `bytes`, found with `memchr` so a count of a step's output
    /// runs at memory speed in any build.
    private static func newlineCount(in bytes: [UInt8]) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            guard var cursor = buffer.baseAddress else { return 0 }
            let end = cursor + buffer.count
            var count = 0
            while cursor < end, let found = memchr(cursor, 0x0A, end - cursor) {
                count += 1
                cursor = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) + 1
            }
            return count
        }
    }

    package static func readRecord(
        from reader: FASTQRawLineReader, file: String, recordNumber: Int
    ) throws -> [[UInt8]]? {
        guard let header = try reader.nextLine() else { return nil }
        guard header.first == UInt8(ascii: "@") else {
            throw InterleaveError.malformedRecord(file: file, recordNumber: recordNumber, reason: "header line does not start with '@'")
        }
        guard let sequence = try reader.nextLine(),
              let separator = try reader.nextLine(),
              let quality = try reader.nextLine() else {
            throw InterleaveError.malformedRecord(file: file, recordNumber: recordNumber, reason: "file ends inside the record")
        }
        guard separator.first == UInt8(ascii: "+") else {
            throw InterleaveError.malformedRecord(file: file, recordNumber: recordNumber, reason: "separator line does not start with '+'")
        }
        guard sequence.count == quality.count else {
            throw InterleaveError.malformedRecord(
                file: file, recordNumber: recordNumber,
                reason: "sequence length \(sequence.count) differs from quality length \(quality.count)"
            )
        }
        return [header, sequence, separator, quality]
    }
}
