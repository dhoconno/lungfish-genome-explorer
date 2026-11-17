// UMILayoutCheck.swift - The UMI layout check's one rule: its argv, the pair choice, the motif tests, the distinct UMIs
// and the names (Phase 5.3 lane EX-UMI, rulings ARCH-UMI-CHECKER and BIO-UMI-SHARE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The layout check of a UMI chain, the first `tool` step of the UMI branch (docs/formats/executor-plan.md, The UMI
/// layout check). `lungfish-executor umi-layout-check` parses ``Arguments``, reads the pairs the ``Choice`` takes and
/// writes the ``Report`` as a `home` file. The checker has no defaults: the motif, the UMI's length and read, the pair
/// count, the choice and every bar come in through the argv, which the plan writer builds from the kit preset.
///
/// Every gating share divides by the pairs read (BIO-UMI-SHARE item 1). The test within one mismatch keeps
/// `scripts/repro/rnaseq/gse163196/layout.py`'s rule, a read of at least the motif's length, and the exact test and the
/// distinct UMIs take only a read that holds the motif and the whole UMI, as the extraction regex needs (item 6).
package enum UMILayoutCheck {
    package static let subcommand = "umi-layout-check"
    package static let usage = "usage: lungfish-executor umi-layout-check --read1 <file> --read2 <file> --decompressor <tool id> "
        + "--kit <label> --motif <bases> --umi-length <bases> --umi-read <1|2> --pairs <count> --choice <first|even> "
        + "--within-one-mismatch-pass <percent> --exact-warn <percent> --distinct-fail <percent> --distinct-warn <percent> "
        + "--output <file>\n"

    /// How the check chooses its pairs. `first` takes the first pairs of the files, as `layout.py` does. `even` counts the
    /// records of both files, then takes `pairs` pairs at evenly spaced indices, so a clumped file is sampled through its
    /// whole length (executor-plan.md:196).
    package enum Choice: String, Codable, Sendable, CaseIterable {
        case first
        case even

        /// The 0-based record indices the choice takes from a file of `total` records, in order: every record when the
        /// file holds no more than `pairs`, else index `i * total / pairs` for `i` from 0.
        package func indices(total: Int, pairs: Int) -> [Int] {
            let count = Swift.min(total, pairs)
            guard count > 0 else { return [] }
            switch self {
            case .first: return Array(0..<count)
            case .even: return (0..<count).map { Int(Int64($0) * Int64(total) / Int64(count)) }
            }
        }
    }

    /// The bars, each a whole percent of the pairs read. A count is compared with a bar as `count * 100` against
    /// `bar * pairs read`, never as a rounded share (BIO-UMI-SHARE item 5).
    package struct Bars: Codable, Equatable, Sendable {
        /// The motif within one mismatch fails under this share.
        package var withinOneMismatchPass: Int
        /// The exact motif warns under this share.
        package var exactWarn: Int
        /// Distinct UMIs fail under this share.
        package var distinctFail: Int
        /// Distinct UMIs warn under this share.
        package var distinctWarn: Int

        package init(withinOneMismatchPass: Int, exactWarn: Int, distinctFail: Int, distinctWarn: Int) {
            self.withinOneMismatchPass = withinOneMismatchPass
            self.exactWarn = exactWarn
            self.distinctFail = distinctFail
            self.distinctWarn = distinctWarn
        }
    }

    /// A missing, unknown, repeated or bad flag. The subcommand exits 64 with ``usage``.
    package struct UsageError: Error, Equatable, Sendable {
        package let message: String

        package init(_ message: String) {
            self.message = message
        }
    }

    /// The step's argv, with every path relative to the work root and the decompressor named by its pinned tool id,
    /// which the step finds on its `PATH` (ARCH-UMI-CHECKER item 4).
    package struct Arguments: Equatable, Sendable {
        package var read1: String
        package var read2: String
        package var decompressor: String
        /// The kit preset's label, which the words name.
        package var kit: String
        package var motif: String
        package var umiLength: Int
        /// The read that starts with the motif and the UMI, 1 or 2.
        package var umiRead: Int
        package var pairs: Int
        package var choice: Choice
        package var bars: Bars
        /// The `home` file the step writes.
        package var output: String

        package init(
            read1: String, read2: String, decompressor: String, kit: String, motif: String, umiLength: Int, umiRead: Int,
            pairs: Int, choice: Choice, bars: Bars, output: String
        ) {
            self.read1 = read1
            self.read2 = read2
            self.decompressor = decompressor
            self.kit = kit
            self.motif = motif
            self.umiLength = umiLength
            self.umiRead = umiRead
            self.pairs = pairs
            self.choice = choice
            self.bars = bars
            self.output = output
        }

        static let flags = [
            "--read1", "--read2", "--decompressor", "--kit", "--motif", "--umi-length", "--umi-read", "--pairs", "--choice",
            "--within-one-mismatch-pass", "--exact-warn", "--distinct-fail", "--distinct-warn", "--output",
        ]

        /// The step's argv, the subcommand first, then each flag once in the order of ``flags``.
        package var argv: [String] {
            let values = [
                read1, read2, decompressor, kit, motif, String(umiLength), String(umiRead), String(pairs), choice.rawValue,
                String(bars.withinOneMismatchPass), String(bars.exactWarn), String(bars.distinctFail), String(bars.distinctWarn),
                output,
            ]
            return [UMILayoutCheck.subcommand] + zip(Self.flags, values).flatMap { [$0, $1] }
        }

        /// Parses `argv`, with or without the subcommand first. Every flag is needed once, and nothing has a default.
        package init(argv: [String]) throws {
            var rest = argv.first == UMILayoutCheck.subcommand ? Array(argv.dropFirst()) : argv
            var values: [String: String] = [:]
            while let flag = rest.first {
                guard flag.hasPrefix("--") else { throw UsageError("unexpected argument \(flag)") }
                guard Self.flags.contains(flag) else { throw UsageError("unknown option \(flag)") }
                guard rest.count > 1 else { throw UsageError("\(flag) needs a value") }
                guard values[flag] == nil else { throw UsageError("\(flag) is given twice") }
                values[flag] = rest[1]
                rest.removeFirst(2)
            }
            func text(_ flag: String) throws -> String {
                guard let value = values[flag] else { throw UsageError("\(flag) is missing") }
                guard !value.isEmpty else { throw UsageError("\(flag) needs a value") }
                return value
            }
            func number(_ flag: String, _ range: ClosedRange<Int>) throws -> Int {
                guard let value = Int(try text(flag)), range.contains(value) else {
                    throw UsageError("\(flag) takes a whole number from \(range.lowerBound) to \(range.upperBound)")
                }
                return value
            }
            func path(_ flag: String) throws -> String {
                let value = try text(flag)
                let parts = value.split(separator: "/", omittingEmptySubsequences: false)
                guard !value.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw UsageError("\(flag) takes a path relative to the work root")
                }
                return value
            }
            for flag in Self.flags { _ = try text(flag) }
            let motif = try text("--motif")
            guard motif.allSatisfy({ "ACGT".contains($0) }) else { throw UsageError("--motif takes the bases A, C, G and T") }
            let decompressor = try text("--decompressor")
            guard !decompressor.contains("/") else { throw UsageError("--decompressor takes a pinned tool id, not a path") }
            guard let choice = Choice(rawValue: try text("--choice")) else { throw UsageError("--choice takes first or even") }
            self.init(
                read1: try path("--read1"), read2: try path("--read2"), decompressor: decompressor, kit: try text("--kit"),
                motif: motif, umiLength: try number("--umi-length", 1...64), umiRead: try number("--umi-read", 1...2),
                pairs: try number("--pairs", 1...10_000_000), choice: choice,
                bars: Bars(
                    withinOneMismatchPass: try number("--within-one-mismatch-pass", 0...100),
                    exactWarn: try number("--exact-warn", 0...100), distinctFail: try number("--distinct-fail", 0...100),
                    distinctWarn: try number("--distinct-warn", 0...100)),
                output: try path("--output"))
        }
    }

    /// What the check counted. `read1Reads` and `read2Reads` are the records each file gave within the pairs to read
    /// under `first`, and each file's whole record count under `even`, so unequal values mean the files are not a pair.
    package struct Counts: Codable, Equatable, Sendable {
        package var pairsRequested: Int
        package var pairsRead: Int
        package var read1Reads: Int
        package var read2Reads: Int
        package var namesEqual: Int
        package var withinOneMismatch: Int
        package var exact: Int
        /// Distinct UMIs, counted among the pairs that hold the exact motif and the whole UMI.
        package var distinctUMIs: Int
        /// The pairs whose names differ only as `<name>/1` and `<name>/2`, a share of those not in `namesEqual`. Nil in a
        /// check file written before milestone 3, which cut names at `/`.
        package var mateSuffixPairs: Int?

        package init(
            pairsRequested: Int, pairsRead: Int, read1Reads: Int, read2Reads: Int, namesEqual: Int, withinOneMismatch: Int,
            exact: Int, distinctUMIs: Int, mateSuffixPairs: Int? = nil
        ) {
            self.pairsRequested = pairsRequested
            self.pairsRead = pairsRead
            self.read1Reads = read1Reads
            self.read2Reads = read2Reads
            self.namesEqual = namesEqual
            self.withinOneMismatch = withinOneMismatch
            self.exact = exact
            self.distinctUMIs = distinctUMIs
            self.mateSuffixPairs = mateSuffixPairs
        }
    }

    /// The counts of the pairs read, one pair at a time.
    package struct Tally: Sendable {
        let motif: [UInt8]
        let umiLength: Int
        package private(set) var pairsRead = 0
        package private(set) var namesEqual = 0
        package private(set) var withinOneMismatch = 0
        package private(set) var exact = 0
        package private(set) var mateSuffixPairs = 0
        private var umis = Set<[UInt8]>()

        package init(motif: String, umiLength: Int) {
            self.motif = Array(motif.utf8)
            self.umiLength = umiLength
        }

        package var distinctUMIs: Int { umis.count }

        /// One pair: both header lines and the sequence of the read that holds the motif and the UMI.
        package mutating func add(header1: [UInt8], umiRead: [UInt8], header2: [UInt8]) {
            pairsRead += 1
            let (name1, name2) = (Self.name(header1), Self.name(header2))
            if name1 == name2 {
                namesEqual += 1
            } else if name1.count == name2.count, name1.suffix(2).elementsEqual("/1".utf8),
                      name2.suffix(2).elementsEqual("/2".utf8), name1.dropLast(2).elementsEqual(name2.dropLast(2)) {
                mateSuffixPairs += 1
            }
            var sequence = umiRead[...]
            while let last = sequence.last, last == 0x0D || last == 0x20 { sequence.removeLast() }
            guard sequence.count >= motif.count else { return }
            var mismatches = 0
            for (base, expected) in zip(sequence, motif) where base != expected { mismatches += 1 }
            if mismatches <= 1 { withinOneMismatch += 1 }
            guard mismatches == 0, sequence.count >= motif.count + umiLength else { return }
            exact += 1
            let start = sequence.startIndex + motif.count
            umis.insert(Array(sequence[start..<(start + umiLength)]))
        }

        /// A read's name, the header's whole first word, as `umi_tools extract` compares the mates (EX-UMI-M2-BIO ruling 1
        /// (b)). `layout.py` cut it at the first `/` as well, which let `x/1` and `x/2` pass here and stop extraction.
        static func name(_ header: [UInt8]) -> ArraySlice<UInt8> {
            let end = header.firstIndex { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D } ?? header.endIndex
            return header[..<end]
        }
    }
}
