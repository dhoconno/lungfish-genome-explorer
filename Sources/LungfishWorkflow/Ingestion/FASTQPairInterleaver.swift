// FASTQPairInterleaver.swift - Verbatim R1/R2 interleaving for paired FASTQ imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Streams a paired R1/R2 FASTQ into one interleaved FASTQ without any
/// external tool, and counts FASTQ records for import integrity checks.
///
/// A paired import that skips storage optimization used to keep only the R1
/// file while its metadata claimed an interleaved pair (data loss). This type
/// writes the layout the clumpify path produces: each R1 record immediately
/// followed by its R2 mate, with every line copied byte for byte. It refuses
/// mismatched mate counts instead of silently truncating either file.
public enum FASTQPairInterleaver {

    public struct Counts: Sendable, Equatable {
        public let r1Records: Int
        public let r2Records: Int
        public let writtenRecords: Int
    }

    public enum InterleaveError: Error, LocalizedError, Equatable {
        case malformedRecord(file: String, recordNumber: Int, reason: String)
        case mateCountMismatch(r1File: String, r1Records: Int, r2File: String, r2Records: Int)
        case recordCountMismatch(expected: Int, actual: Int)
        case unreadableInput(file: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .malformedRecord(let file, let recordNumber, let reason):
                return "Malformed FASTQ record \(recordNumber) in \(file): \(reason)"
            case .mateCountMismatch(let r1File, let r1Records, let r2File, let r2Records):
                return "Paired FASTQ mates do not match: \(r1File) has \(r1Records) reads but \(r2File) has \(r2Records). Nothing was imported."
            case .recordCountMismatch(let expected, let actual):
                return "Paired import integrity check failed: expected \(expected) interleaved reads (R1 + R2) but the output holds \(actual). Nothing was imported."
            case .unreadableInput(let file, let reason):
                return "Cannot read \(file): \(reason)"
            }
        }
    }

    /// Writes R1 and R2 records alternately to `sink`.
    ///
    /// Both inputs may be plain or gzip-compressed. Throws before finishing
    /// when either file runs out of records first, so the caller never keeps
    /// a truncated output.
    public static func interleave(r1: URL, r2: URL, to sink: FileHandle) throws -> Counts {
        let reader1 = try FASTQRawLineReader(url: r1)
        defer { reader1.close() }
        let reader2 = try FASTQRawLineReader(url: r2)
        defer { reader2.close() }

        var output = BufferedSink(handle: sink)
        var r1Count = 0
        var r2Count = 0

        while true {
            if r1Count & 0x3FFF == 0 { try Task.checkCancellation() }
            let record1 = try readRecord(from: reader1, file: r1.lastPathComponent, recordNumber: r1Count + 1)
            let record2 = try readRecord(from: reader2, file: r2.lastPathComponent, recordNumber: r2Count + 1)
            if record1 != nil { r1Count += 1 }
            if record2 != nil { r2Count += 1 }
            guard let record1, let record2 else {
                if record1 != nil || record2 != nil {
                    // Drain both files so the error names the true counts.
                    while try readRecord(from: reader1, file: r1.lastPathComponent, recordNumber: r1Count + 1) != nil {
                        r1Count += 1
                    }
                    while try readRecord(from: reader2, file: r2.lastPathComponent, recordNumber: r2Count + 1) != nil {
                        r2Count += 1
                    }
                    throw InterleaveError.mateCountMismatch(
                        r1File: r1.lastPathComponent, r1Records: r1Count,
                        r2File: r2.lastPathComponent, r2Records: r2Count
                    )
                }
                break
            }
            try output.write(record1)
            try output.write(record2)
        }
        try output.flush()

        let written = output.recordsWritten
        guard written == r1Count + r2Count else {
            throw InterleaveError.recordCountMismatch(expected: r1Count + r2Count, actual: written)
        }
        return Counts(r1Records: r1Count, r2Records: r2Count, writtenRecords: written)
    }

    /// Splits a strictly interleaved FASTQ back into R1 and R2 streams.
    ///
    /// Records alternate R1, R2, R1, R2 and are copied byte for byte. An odd
    /// record count means the file is not a whole set of pairs and throws;
    /// nothing checks read names because the caller has already classified
    /// the layout with `FASTQReadLayoutClassifier`.
    public static func deinterleave(interleaved: URL, r1 sink1: FileHandle, r2 sink2: FileHandle) throws -> Counts {
        let reader = try FASTQRawLineReader(url: interleaved)
        defer { reader.close() }
        var output1 = BufferedSink(handle: sink1)
        var output2 = BufferedSink(handle: sink2)
        var total = 0
        let file = interleaved.lastPathComponent

        while let record1 = try readRecord(from: reader, file: file, recordNumber: total + 1) {
            total += 1
            if total & 0x3FFF == 0 { try Task.checkCancellation() }
            guard let record2 = try readRecord(from: reader, file: file, recordNumber: total + 1) else {
                throw InterleaveError.mateCountMismatch(
                    r1File: file, r1Records: total / 2 + 1,
                    r2File: file, r2Records: total / 2
                )
            }
            total += 1
            try output1.write(record1)
            try output2.write(record2)
        }
        try output1.flush()
        try output2.flush()

        let written = output1.recordsWritten + output2.recordsWritten
        guard written == total, output1.recordsWritten == output2.recordsWritten else {
            throw InterleaveError.recordCountMismatch(expected: total, actual: written)
        }
        return Counts(r1Records: output1.recordsWritten, r2Records: output2.recordsWritten, writtenRecords: written)
    }

    /// Record counts of a by-name partition of a mixed file.
    public struct MixedCounts: Sendable, Equatable {
        /// Adjacent mate pairs found and written as pairs.
        public let pairs: Int
        /// Records without an adjacent mate (merged or orphan reads).
        public let unpaired: Int

        public init(pairs: Int, unpaired: Int) {
            self.pairs = pairs
            self.unpaired = unpaired
        }
    }

    /// Splits a file that mixes adjacent mate pairs with unpaired reads into
    /// R1, R2, and unpaired streams, pairing records by NAME rather than by
    /// position.
    ///
    /// Two adjacent records are mates under ``FASTQReadLayoutClassifier``'s
    /// rule (identical read IDs, `/1` `/2` suffixes, or Casava descriptions).
    /// Every other record goes to `unpaired` in its original order. Records
    /// are copied byte for byte. A strictly interleaved file comes out with
    /// an empty unpaired stream, so callers may use this for both layouts.
    public static func partitionMixed(
        interleaved: URL,
        r1 sink1: FileHandle,
        r2 sink2: FileHandle,
        unpaired sinkUnpaired: FileHandle
    ) throws -> MixedCounts {
        var output1 = BufferedSink(handle: sink1)
        var output2 = BufferedSink(handle: sink2)
        var outputUnpaired = BufferedSink(handle: sinkUnpaired)
        let counts = try partitionMixed(
            interleaved: interleaved,
            onPair: { first, second in
                try output1.write(first)
                try output2.write(second)
            },
            onUnpaired: { record in try outputUnpaired.write(record) }
        )
        try output1.flush()
        try output2.flush()
        try outputUnpaired.flush()
        return counts
    }

    /// Splits a mixed file into one interleaved file of whole pairs and one
    /// file of unpaired reads, pairing records by name.
    ///
    /// The pairs file is strictly interleaved, so a tool that pairs by
    /// position (`bbmerge interleaved=t`, `reformat interleaved=t`) can run on
    /// it safely; the unpaired reads pass around that tool untouched.
    public static func partitionMixed(
        interleaved: URL,
        pairs sinkPairs: FileHandle,
        unpaired sinkUnpaired: FileHandle
    ) throws -> MixedCounts {
        var outputPairs = BufferedSink(handle: sinkPairs)
        var outputUnpaired = BufferedSink(handle: sinkUnpaired)
        let counts = try partitionMixed(
            interleaved: interleaved,
            onPair: { first, second in
                try outputPairs.write(first)
                try outputPairs.write(second)
            },
            onUnpaired: { record in try outputUnpaired.write(record) }
        )
        try outputPairs.flush()
        try outputUnpaired.flush()
        return counts
    }

    private static func partitionMixed(
        interleaved: URL,
        onPair: ([[UInt8]], [[UInt8]]) throws -> Void,
        onUnpaired: ([[UInt8]]) throws -> Void
    ) throws -> MixedCounts {
        let reader = try FASTQRawLineReader(url: interleaved)
        defer { reader.close() }
        let file = interleaved.lastPathComponent
        var total = 0
        var pairs = 0
        var unpaired = 0
        var pending: [[UInt8]]? = nil

        while let record = try readRecord(from: reader, file: file, recordNumber: total + 1) {
            total += 1
            if total & 0x3FFF == 0 { try Task.checkCancellation() }
            guard let previous = pending else {
                pending = record
                continue
            }
            if FASTQReadLayoutClassifier.areMates(headerText(previous[0]), headerText(record[0])) {
                try onPair(previous, record)
                pairs += 1
                pending = nil
            } else {
                try onUnpaired(previous)
                unpaired += 1
                pending = record
            }
        }
        if let last = pending {
            try onUnpaired(last)
            unpaired += 1
        }
        return MixedCounts(pairs: pairs, unpaired: unpaired)
    }

    /// The header line without its leading `@`, as the classifier expects.
    private static func headerText(_ line: [UInt8]) -> String {
        String(decoding: line.dropFirst(), as: UTF8.self)
    }

    /// Counts four-line FASTQ records in a plain or gzip-compressed file.
    ///
    /// Throws when the line count is not a multiple of four, which is the
    /// signature of a truncated write.
    public static func countRecords(in url: URL) throws -> Int {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var lines = 0
        var lastByte: UInt8 = 0x0A
        var sawBytes = false
        while let chunk = try reader.readChunk() {
            if chunk.isEmpty { continue }
            sawBytes = true
            for byte in chunk where byte == 0x0A { lines += 1 }
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

    private static func readRecord(
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

    private struct BufferedSink {
        let handle: FileHandle
        var buffer: [UInt8] = []
        var recordsWritten = 0
        private let flushThreshold = 4 * 1_048_576

        init(handle: FileHandle) {
            self.handle = handle
            buffer.reserveCapacity(flushThreshold + 65_536)
        }

        mutating func write(_ lines: [[UInt8]]) throws {
            for line in lines {
                buffer.append(contentsOf: line)
                buffer.append(0x0A)
            }
            recordsWritten += 1
            if buffer.count >= flushThreshold { try flush() }
        }

        mutating func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

/// Pull-based byte line reader over a plain or gzip/BGZF file.
///
/// Gzip input is decompressed through `/usr/bin/gzip -dc`, the same route
/// `GzipLineSource` takes, because it handles concatenated BGZF members.
final class FASTQRawLineReader {
    private let url: URL
    private let handle: FileHandle
    private let process: Process?
    private var buffer: [UInt8] = []
    private var position = 0
    private var reachedEnd = false
    private var closed = false
    private let chunkSize = 1_048_576

    init(url: URL) throws {
        self.url = url
        guard let probe = FileHandle(forReadingAtPath: url.path) else {
            throw FASTQPairInterleaver.InterleaveError.unreadableInput(file: url.lastPathComponent, reason: "file not found or not readable")
        }
        let magic = (try? probe.read(upToCount: 2)) ?? Data()
        let isGzip = magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
        if isGzip {
            try? probe.close()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process
            self.handle = stdout.fileHandleForReading
        } else {
            try probe.seek(toOffset: 0)
            self.process = nil
            self.handle = probe
        }
    }

    deinit { close() }

    func nextLine() throws -> [UInt8]? {
        while true {
            if let newline = indexOfNewline() {
                let line = Array(buffer[position..<newline])
                position = newline + 1
                return line
            }
            if reachedEnd {
                guard position < buffer.count else { return nil }
                let line = Array(buffer[position..<buffer.count])
                position = buffer.count
                return line
            }
            try fill()
        }
    }

    func readChunk() throws -> [UInt8]? {
        guard !reachedEnd else { return nil }
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty {
            try finishInput()
            return nil
        }
        return [UInt8](data)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.close()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func indexOfNewline() -> Int? {
        guard position < buffer.count else { return nil }
        let start = position
        return buffer.withUnsafeBufferPointer { pointer -> Int? in
            guard let base = pointer.baseAddress,
                  let found = memchr(base + start, 0x0A, pointer.count - start) else { return nil }
            return UnsafePointer<UInt8>(found.assumingMemoryBound(to: UInt8.self)) - base
        }
    }

    private func fill() throws {
        if position > 0 {
            buffer.removeSubrange(0..<position)
            position = 0
        }
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        if data.isEmpty {
            try finishInput()
        } else {
            buffer.append(contentsOf: data)
        }
    }

    private func finishInput() throws {
        reachedEnd = true
        guard let process else { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FASTQPairInterleaver.InterleaveError.unreadableInput(
                file: url.lastPathComponent, reason: "gzip decompression failed (exit \(process.terminationStatus))"
            )
        }
    }
}
