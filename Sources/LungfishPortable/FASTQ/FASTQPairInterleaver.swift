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

extension FASTQPairInterleaver {

    public struct Counts: Sendable, Equatable {
        public let r1Records: Int
        public let r2Records: Int
        public let writtenRecords: Int

        package init(r1Records: Int, r2Records: Int, writtenRecords: Int) {
            self.r1Records = r1Records
            self.r2Records = r2Records
            self.writtenRecords = writtenRecords
        }
    }

    /// Writes R1 and R2 records alternately to `sink`.
    ///
    /// Both inputs may be plain or gzip-compressed. Throws before finishing
    /// when either file runs out of records first, so the caller never keeps
    /// a truncated output. With `requireMates`, every R1/R2 record pair must
    /// also satisfy ``FASTQReadLayoutClassifier/areMates(_:_:)`` (identical
    /// IDs, `/1` `/2`, or Casava comments); the first pair that does not
    /// throws ``InterleaveError/mateNameMismatch(recordNumber:r1File:r1Name:r2File:r2Name:)``,
    /// which is how a caller relying on two files being in lockstep (fastp's
    /// unmerged outputs) finds out they are not.
    package static func interleave(
        r1: URL,
        r2: URL,
        to sink: FileHandle,
        requireMates: Bool = false,
        launcher: any PortableChildLauncher
    ) throws -> Counts {
        var output = BufferedSink(handle: sink)
        return try interleave(r1: r1, r2: r2, into: &output, requireMates: requireMates, launcher: launcher)
    }

    package static func interleave(
        r1: URL,
        r2: URL,
        into output: inout BufferedSink,
        requireMates: Bool,
        launcher: any PortableChildLauncher
    ) throws -> Counts {
        let counts = try interleave(r1: r1, r2: r2, requireMates: requireMates, launcher: launcher) { record1, record2 in
            try output.write(record1)
            try output.write(record2)
        }
        try output.flush()

        let written = output.recordsWritten
        guard written == counts.r1Records + counts.r2Records else {
            throw InterleaveError.recordCountMismatch(expected: counts.r1Records + counts.r2Records, actual: written)
        }
        return Counts(r1Records: counts.r1Records, r2Records: counts.r2Records, writtenRecords: written)
    }

    /// What ``interleaveRecordedPair(r1:r2:to:)`` wrote.
    public struct RecordedPairCounts: Sendable, Equatable {
        public let counts: Counts
        /// The record pairs whose names carry no mate number, which were
        /// paired by position alone.
        public let pairedByPosition: Int
        /// The R1 and R2 names of the first of those pairs.
        public let firstPairedByPosition: [String]?
    }

    /// What the names of an R1 record and the R2 record beside it say.
    public enum RecordedMates: Sendable, Equatable {
        /// The names are the R1 and R2 of one fragment.
        case mates
        /// A name carries no mate number, so only position pairs the records.
        case unmarked
        /// Both names carry a mate number and are not R1 and R2 of one fragment.
        case notMates
    }

    /// Writes the records of the R1 and R2 files of one recorded pair (a
    /// `fullPaired` or `fullMixed` bundle) alternately to `sink`, paired by
    /// position as reformat.sh `interleaved=t` paired them.
    ///
    /// Names that carry a mate number are checked (``recordedMates(_:_:)``),
    /// and a pair of them that are not mates throws
    /// ``InterleaveError/mateNameMismatch(recordNumber:r1File:r1Name:r2File:r2Name:)``,
    /// because the files are out of step. A pair of names that carry none is
    /// paired by position and counted, so the caller can warn. Files that
    /// hold different numbers of records throw. A legacy bundle whose mates
    /// are named `x.1` and `x.2` threw before this rule (final review A, N2).
    package static func interleaveRecordedPair(
        r1: URL, r2: URL, to sink: FileHandle, launcher: any PortableChildLauncher
    ) throws -> RecordedPairCounts {
        var output = BufferedSink(handle: sink)
        return try interleaveRecordedPair(r1: r1, r2: r2, into: &output, launcher: launcher)
    }

    package static func interleaveRecordedPair(
        r1: URL,
        r2: URL,
        into output: inout BufferedSink,
        launcher: any PortableChildLauncher
    ) throws -> RecordedPairCounts {
        var recordNumber = 0
        var pairedByPosition = 0
        var firstPairedByPosition: [String]?
        let counts = try interleave(r1: r1, r2: r2, requireMates: false, launcher: launcher) { record1, record2 in
            recordNumber += 1
            let name1 = headerText(record1[0])
            let name2 = headerText(record2[0])
            switch recordedMates(name1, name2) {
            case .mates:
                break
            case .unmarked:
                pairedByPosition += 1
                if firstPairedByPosition == nil { firstPairedByPosition = [name1, name2] }
            case .notMates:
                throw InterleaveError.mateNameMismatch(
                    recordNumber: recordNumber,
                    r1File: r1.lastPathComponent, r1Name: name1,
                    r2File: r2.lastPathComponent, r2Name: name2
                )
            }
            try output.write(record1)
            try output.write(record2)
        }
        try output.flush()
        let written = output.recordsWritten
        guard written == counts.r1Records + counts.r2Records else {
            throw InterleaveError.recordCountMismatch(expected: counts.r1Records + counts.r2Records, actual: written)
        }
        return RecordedPairCounts(
            counts: Counts(r1Records: counts.r1Records, r2Records: counts.r2Records, writtenRecords: written),
            pairedByPosition: pairedByPosition,
            firstPairedByPosition: firstPairedByPosition
        )
    }

    /// Whether `name1` and `name2`, the records at one position of the R1
    /// and R2 files of one recorded pair, are mates.
    /// ``FASTQReadLayoutClassifier/areMates(_:_:)`` decides first. The read
    /// ID suffixes `.1` `.2` and `_1` `_2` count as mate numbers here only,
    /// beside `/1` `/2` and Casava comments, because a file of single reads
    /// may number its reads that way (SRA spots `SRR1.1`, `SRR1.2`).
    public static func recordedMates(_ name1: String, _ name2: String) -> RecordedMates {
        if FASTQReadLayoutClassifier.areMates(name1, name2) { return .mates }
        guard let mark1 = mateNumber(of: name1), let mark2 = mateNumber(of: name2) else { return .unmarked }
        return mark1.fragment == mark2.fragment && mark1.mate == 1 && mark2.mate == 2 ? .mates : .notMates
    }

    /// The fragment and the mate number a read name carries, from `/1` `/2`,
    /// `.1` `.2` or `_1` `_2` at the end of its read ID, or a Casava
    /// ` 1:N:` comment.
    private static func mateNumber(of name: String) -> (fragment: String, mate: Int)? {
        let header = name.drop(while: { $0 == "@" })
        let readID = header.prefix(while: { $0 != " " && $0 != "\t" })
        if readID.count > 2, let digit = readID.last, digit == "1" || digit == "2",
           "/._".contains(readID[readID.index(readID.endIndex, offsetBy: -2)]) {
            return (String(readID.dropLast(2)), digit == "1" ? 1 : 2)
        }
        if let pair = ReadPair.parse(from: String(header)) {
            return (pair.pairId, pair.readNumber)
        }
        return nil
    }

    private static func interleave(
        r1: URL,
        r2: URL,
        requireMates: Bool,
        launcher: any PortableChildLauncher,
        onPair: ([[UInt8]], [[UInt8]]) throws -> Void
    ) throws -> (r1Records: Int, r2Records: Int) {
        let reader1 = try FASTQRawLineReader(url: r1, launcher: launcher)
        defer { reader1.close() }
        let reader2 = try FASTQRawLineReader(url: r2, launcher: launcher)
        defer { reader2.close() }

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
            if requireMates {
                let name1 = headerText(record1[0])
                let name2 = headerText(record2[0])
                guard FASTQReadLayoutClassifier.areMates(name1, name2) else {
                    throw InterleaveError.mateNameMismatch(
                        recordNumber: r1Count,
                        r1File: r1.lastPathComponent, r1Name: name1,
                        r2File: r2.lastPathComponent, r2Name: name2
                    )
                }
            }
            try onPair(record1, record2)
        }
        return (r1Count, r2Count)
    }

    /// Writes a mixed file: every merged record first, then each unmerged
    /// R1 record immediately followed by its R2 mate.
    ///
    /// The unmerged files must be in lockstep (fastp's `--out1`/`--out2`
    /// after `--merge` are); every pair is checked by name and the first
    /// mismatch throws, so a file that would later be read as orphans is
    /// never produced. Records are copied byte for byte and the merged file
    /// is validated record by record on the way through. Any of the inputs
    /// may be plain or gzip-compressed; `sink` receives plain FASTQ. With no
    /// unmerged files only the merged reads are copied.
    package static func writeMergedThenPairs(
        merged: URL,
        unmergedR1: URL?,
        unmergedR2: URL?,
        to sink: FileHandle,
        launcher: any PortableChildLauncher
    ) throws -> MergedThenPairsCounts {
        var output = BufferedSink(handle: sink)
        var mergedCount = 0
        do {
            let reader = try FASTQRawLineReader(url: merged, launcher: launcher)
            defer { reader.close() }
            let file = merged.lastPathComponent
            while let record = try readRecord(from: reader, file: file, recordNumber: mergedCount + 1) {
                mergedCount += 1
                if mergedCount & 0x3FFF == 0 { try Task.checkCancellation() }
                try output.write(record)
            }
        }
        var pairCount = 0
        if let unmergedR1, let unmergedR2 {
            let pairs = try interleave(
                r1: unmergedR1, r2: unmergedR2, requireMates: true, launcher: launcher
            ) { record1, record2 in
                try output.write(record1)
                try output.write(record2)
            }
            pairCount = pairs.r1Records
        } else if unmergedR1 != nil || unmergedR2 != nil {
            let present = unmergedR1 ?? unmergedR2
            throw InterleaveError.unreadableInput(
                file: present?.lastPathComponent ?? "",
                reason: "an unmerged mate file was given without its partner"
            )
        }
        try output.flush()

        let expected = mergedCount + pairCount * 2
        guard output.recordsWritten == expected else {
            throw InterleaveError.recordCountMismatch(expected: expected, actual: output.recordsWritten)
        }
        return MergedThenPairsCounts(mergedRecords: mergedCount, pairs: pairCount)
    }

    /// Copies every record of `file` to `sink` byte for byte, each record's
    /// shape checked as ``writeMergedThenPairs(merged:unmergedR1:unmergedR2:to:)``
    /// checks the merged reads, and returns the records written.
    ///
    /// `inspect` sees each record's header without its `@` and its 1-based
    /// number before the record is written, so a caller can refuse the file
    /// by throwing. Plain or gzip input, plain output.
    package static func copyRecords(
        of file: URL,
        to sink: FileHandle,
        launcher: any PortableChildLauncher,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        var output = BufferedSink(handle: sink)
        return try copyRecords(of: file, into: &output, launcher: launcher, inspecting: inspect)
    }

    package static func copyRecords(
        of file: URL,
        into output: inout BufferedSink,
        launcher: any PortableChildLauncher,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        let reader = try FASTQRawLineReader(url: file, launcher: launcher)
        defer { reader.close() }
        var count = 0
        while let record = try readRecord(from: reader, file: file.lastPathComponent, recordNumber: count + 1) {
            count += 1
            if count & 0x3FFF == 0 { try Task.checkCancellation() }
            try inspect(headerText(record[0]), count)
            try output.write(record)
        }
        try output.flush()
        return count
    }

    /// What ``writeMergedThenPairs(merged:unmergedR1:unmergedR2:to:)`` wrote.
    public struct MergedThenPairsCounts: Sendable, Equatable {
        public let mergedRecords: Int
        public let pairs: Int

        public var writtenRecords: Int { mergedRecords + pairs * 2 }
    }

    /// Splits a strictly interleaved FASTQ back into R1 and R2 streams.
    ///
    /// Records alternate R1, R2, R1, R2 and are copied byte for byte. An odd
    /// record count means the file is not a whole set of pairs and throws;
    /// nothing checks read names because the caller has already classified
    /// the layout with `FASTQReadLayoutClassifier`.
    package static func deinterleave(
        interleaved: URL, r1 sink1: FileHandle, r2 sink2: FileHandle, launcher: any PortableChildLauncher
    ) throws -> Counts {
        let reader = try FASTQRawLineReader(url: interleaved, launcher: launcher)
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
    package static func partitionMixed(
        interleaved: URL,
        r1 sink1: FileHandle,
        r2 sink2: FileHandle,
        unpaired sinkUnpaired: FileHandle,
        launcher: any PortableChildLauncher
    ) throws -> MixedCounts {
        var output1 = BufferedSink(handle: sink1)
        var output2 = BufferedSink(handle: sink2)
        var outputUnpaired = BufferedSink(handle: sinkUnpaired)
        let counts = try partitionMixed(
            interleaved: interleaved,
            launcher: launcher,
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
    package static func partitionMixed(
        interleaved: URL,
        pairs sinkPairs: FileHandle,
        unpaired sinkUnpaired: FileHandle,
        launcher: any PortableChildLauncher
    ) throws -> MixedCounts {
        var outputPairs = BufferedSink(handle: sinkPairs)
        var outputUnpaired = BufferedSink(handle: sinkUnpaired)
        let counts = try partitionMixed(
            interleaved: interleaved,
            launcher: launcher,
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

    /// Counts the adjacent mate pairs and unpaired records of a file without
    /// writing anything, using the same by-name rule as ``partitionMixed``.
    ///
    /// `unpaired == 0` means every record is followed by its mate (strictly
    /// interleaved, so the record count is even); `pairs == 0` means no
    /// record has its mate next to it.
    package static func countMixed(interleaved: URL, launcher: any PortableChildLauncher) throws -> MixedCounts {
        try partitionMixed(interleaved: interleaved, launcher: launcher, onPair: { _, _ in }, onUnpaired: { _ in })
    }

    private static func partitionMixed(
        interleaved: URL,
        launcher: any PortableChildLauncher,
        onPair: ([[UInt8]], [[UInt8]]) throws -> Void,
        onUnpaired: ([[UInt8]]) throws -> Void
    ) throws -> MixedCounts {
        let reader = try FASTQRawLineReader(url: interleaved, launcher: launcher)
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

    /// Buffers whole records and hands them to `emit` about 4 MiB at a time.
    package struct BufferedSink {
        private let emit: ([UInt8]) throws -> Void
        var buffer: [UInt8] = []
        var recordsWritten = 0
        private let flushThreshold = 4 * 1_048_576

        /// A sink that hands each full buffer to `emit`, which reports a
        /// failed write as a thrown error.
        package init(emit: @escaping ([UInt8]) throws -> Void) {
            self.emit = emit
            buffer.reserveCapacity(flushThreshold + 65_536)
        }

        init(handle: FileHandle) {
            self.init(emit: { try handle.write(contentsOf: $0) })
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
            try emit(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
}
