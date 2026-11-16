// UMILayoutCheck+Read.swift - The pairs the UMI layout check reads, by its pinned choice (Phase 5.3 lane EX-UMI,
// ARCH-UMI-CHECKER item 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension UMILayoutCheck {
    /// A read file that is no FASTQ of four lines a read, or that ends inside a read.
    package struct ReadError: Error, Equatable, Sendable, LocalizedError {
        package let message: String

        package var errorDescription: String? { message }
    }

    /// Reads the pairs `arguments.choice` takes from `read1` and `read2`, a gzip file through `launcher`'s decompressor,
    /// and counts them. Under `first` both files are read to the pairs requested, so a file that ends before the other
    /// shows in `read1Reads` and `read2Reads`. Under `even` both files are counted first, and files of unequal counts are
    /// reported with no pair read.
    package static func measure(
        _ arguments: Arguments, read1: URL, read2: URL, launcher: any PortableChildLauncher
    ) throws -> Counts {
        var counts = Counts(
            pairsRequested: arguments.pairs, pairsRead: 0, read1Reads: 0, read2Reads: 0, namesEqual: 0, withinOneMismatch: 0,
            exact: 0, distinctUMIs: 0)
        var wanted: [Int]?
        if arguments.choice == .even {
            counts.read1Reads = try FASTQPairInterleaver.countRecords(in: read1, launcher: launcher)
            counts.read2Reads = try FASTQPairInterleaver.countRecords(in: read2, launcher: launcher)
            guard counts.read1Reads == counts.read2Reads else { return counts }
            wanted = Choice.even.indices(total: counts.read1Reads, pairs: arguments.pairs)
        }
        let first = try FASTQRawLineReader(url: read1, launcher: launcher)
        defer { first.close() }
        let second = try FASTQRawLineReader(url: read2, launcher: launcher)
        defer { second.close() }
        var tally = Tally(motif: arguments.motif, umiLength: arguments.umiLength)
        let limit = wanted.map { ($0.last ?? -1) + 1 } ?? arguments.pairs
        var next = 0
        var given = (0, 0)
        var ended = (false, false)
        for index in 0..<limit {
            var one: (header: [UInt8], sequence: [UInt8])?
            var two: (header: [UInt8], sequence: [UInt8])?
            if !ended.0 { one = try record(first, file: "Read 1") }
            if !ended.1 { two = try record(second, file: "Read 2") }
            if one == nil { ended.0 = true } else { given.0 += 1 }
            if two == nil { ended.1 = true } else { given.1 += 1 }
            if ended.0 && ended.1 { break }
            guard let one, let two else { continue }
            if let wanted {
                guard next < wanted.count, wanted[next] == index else { continue }
                next += 1
            }
            tally.add(header1: one.header, umiRead: arguments.umiRead == 1 ? one.sequence : two.sequence, header2: two.header)
        }
        if wanted == nil {
            counts.read1Reads = given.0
            counts.read2Reads = given.1
        }
        counts.pairsRead = tally.pairsRead
        counts.namesEqual = tally.namesEqual
        counts.withinOneMismatch = tally.withinOneMismatch
        counts.exact = tally.exact
        counts.distinctUMIs = tally.distinctUMIs
        return counts
    }

    /// The next read's header and sequence, or nil at the file's end.
    static func record(_ reader: FASTQRawLineReader, file: String) throws -> (header: [UInt8], sequence: [UInt8])? {
        guard let header = try reader.nextLine(), !header.isEmpty else { return nil }
        guard header.first == 0x40, let sequence = try reader.nextLine(), let plus = try reader.nextLine(), plus.first == 0x2B,
              try reader.nextLine() != nil else {
            throw ReadError(message: "\(file) is not a FASTQ file of four lines a read, or it ends inside a read.")
        }
        return (header, sequence)
    }
}
