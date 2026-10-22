// FASTQPairInterleaver.swift - Verbatim R1/R2 interleaving for paired FASTQ imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension FASTQPairInterleaver {

    public struct Counts: Sendable, Equatable {
        public let r1Records: Int
        public let r2Records: Int
        public let writtenRecords: Int
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
    public static func interleave(
        r1: URL,
        r2: URL,
        to sink: FileHandle,
        requireMates: Bool = false
    ) throws -> Counts {
        var output = BufferedSink(handle: sink)
        return try interleave(r1: r1, r2: r2, into: &output, requireMates: requireMates)
    }

    /// ``interleave(r1:r2:to:requireMates:)`` into the stage file of a
    /// ``DurableReplace`` publication, so a failed write is a thrown error and
    /// the name holds the interleaved file only when it is whole and synced
    /// (Phase 2.10 lane S31).
    static func interleave(
        r1: URL,
        r2: URL,
        to stage: DurableReplace.StageWriter,
        requireMates: Bool = false
    ) throws -> Counts {
        var output = BufferedSink(stage: stage)
        return try interleave(r1: r1, r2: r2, into: &output, requireMates: requireMates)
    }

    private static func interleave(
        r1: URL,
        r2: URL,
        into output: inout BufferedSink,
        requireMates: Bool
    ) throws -> Counts {
        let counts = try interleave(r1: r1, r2: r2, requireMates: requireMates) { record1, record2 in
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
    public static func interleaveRecordedPair(r1: URL, r2: URL, to sink: FileHandle) throws -> RecordedPairCounts {
        var output = BufferedSink(handle: sink)
        return try interleaveRecordedPair(r1: r1, r2: r2, into: &output)
    }

    /// `interleaveRecordedPair(r1:r2:to:)` with a file handle, into the stage
    /// file of a ``DurableReplace`` publication (Phase 2.10 lane S31).
    static func interleaveRecordedPair(
        r1: URL,
        r2: URL,
        to stage: DurableReplace.StageWriter
    ) throws -> RecordedPairCounts {
        var output = BufferedSink(stage: stage)
        return try interleaveRecordedPair(r1: r1, r2: r2, into: &output)
    }

    private static func interleaveRecordedPair(
        r1: URL,
        r2: URL,
        into output: inout BufferedSink
    ) throws -> RecordedPairCounts {
        var recordNumber = 0
        var pairedByPosition = 0
        var firstPairedByPosition: [String]?
        let counts = try interleave(r1: r1, r2: r2, requireMates: false) { record1, record2 in
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
        onPair: ([[UInt8]], [[UInt8]]) throws -> Void
    ) throws -> (r1Records: Int, r2Records: Int) {
        let reader1 = try FASTQRawLineReader(url: r1)
        defer { reader1.close() }
        let reader2 = try FASTQRawLineReader(url: r2)
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
    public static func writeMergedThenPairs(
        merged: URL,
        unmergedR1: URL?,
        unmergedR2: URL?,
        to sink: FileHandle
    ) throws -> MergedThenPairsCounts {
        var output = BufferedSink(handle: sink)
        var mergedCount = 0
        do {
            let reader = try FASTQRawLineReader(url: merged)
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
            let pairs = try interleave(r1: unmergedR1, r2: unmergedR2, requireMates: true) { record1, record2 in
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
    static func copyRecords(
        of file: URL,
        to sink: FileHandle,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        var output = BufferedSink(handle: sink)
        return try copyRecords(of: file, into: &output, inspecting: inspect)
    }

    /// `copyRecords(of:to:inspecting:)` with a file handle, into the stage
    /// file of a ``DurableReplace`` publication (Phase 2.10 lane S31).
    static func copyRecords(
        of file: URL,
        to stage: DurableReplace.StageWriter,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        var output = BufferedSink(stage: stage)
        return try copyRecords(of: file, into: &output, inspecting: inspect)
    }

    private static func copyRecords(
        of file: URL,
        into output: inout BufferedSink,
        inspecting inspect: (_ header: String, _ recordNumber: Int) throws -> Void
    ) throws -> Int {
        let reader = try FASTQRawLineReader(url: file)
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

    /// Counts the adjacent mate pairs and unpaired records of a file without
    /// writing anything, using the same by-name rule as ``partitionMixed``.
    ///
    /// `unpaired == 0` means every record is followed by its mate (strictly
    /// interleaved, so the record count is even); `pairs == 0` means no
    /// record has its mate next to it.
    public static func countMixed(interleaved: URL) throws -> MixedCounts {
        try partitionMixed(interleaved: interleaved, onPair: { _, _ in }, onUnpaired: { _ in })
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
}

extension FASTQPairInterleaver {

    /// ``countRecords(in:launcher:)`` with the launcher that starts `gzip -dc`
    /// through ``ToolProcess``.
    public static func countRecords(in url: URL) throws -> Int {
        try countRecords(in: url, launcher: ToolProcessChildLauncher())
    }

    private struct BufferedSink {
        private let emit: ([UInt8]) throws -> Void
        var buffer: [UInt8] = []
        var recordsWritten = 0
        private let flushThreshold = 4 * 1_048_576

        init(handle: FileHandle) {
            emit = { try handle.write(contentsOf: $0) }
            buffer.reserveCapacity(flushThreshold + 65_536)
        }

        /// A sink into the stage file of a ``DurableReplace`` publication,
        /// which reports a failed write as a thrown error.
        init(stage: DurableReplace.StageWriter) {
            emit = { bytes in try bytes.withUnsafeBytes { try stage.write($0) } }
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
            try emit(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

extension FASTQRawLineReader {
    /// A reader that starts `gzip -dc` through ``ToolProcess`` for a gzip file.
    convenience init(url: URL) throws {
        try self.init(url: url, launcher: ToolProcessChildLauncher())
    }
}
