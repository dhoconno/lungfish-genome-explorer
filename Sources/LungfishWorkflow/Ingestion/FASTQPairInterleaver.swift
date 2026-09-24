// FASTQPairInterleaver.swift - Verbatim R1/R2 interleaving for paired FASTQ imports
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
