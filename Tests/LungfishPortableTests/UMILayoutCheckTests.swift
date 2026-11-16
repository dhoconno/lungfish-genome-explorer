// UMILayoutCheckTests.swift - The UMI layout check's one rule, its argv and its words (Phase 5.3 lane EX-UMI)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishPortable

/// ARCH-UMI-CHECKER items 2, 3, 9 and 12 and BIO-UMI-SHARE items 1 to 13: one denominator, the pairs read, counts
/// compared and never rounded shares, a share cut down to one decimal, and the words of each verdict.
final class UMILayoutCheckTests: XCTestCase {
    static let kit = "ATCAATC + 16-nt UMI on Read 1"

    static func arguments(choice: UMILayoutCheck.Choice = .first, pairs: Int = 1000) -> UMILayoutCheck.Arguments {
        UMILayoutCheck.Arguments(
            read1: "inputs/pair1_R1.fastq.gz", read2: "inputs/pair1_R2.fastq.gz", decompressor: "pigz", kit: kit,
            motif: "ATCAATC", umiLength: 16, umiRead: 1, pairs: pairs, choice: choice,
            bars: UMILayoutCheck.Bars(withinOneMismatchPass: 90, exactWarn: 90, distinctFail: 50, distinctWarn: 80),
            output: "umi-check/layout-check.json")
    }

    static func counts(pairs: Int = 1000, names: Int? = nil, near: Int, exact: Int, distinct: Int) -> UMILayoutCheck.Counts {
        UMILayoutCheck.Counts(pairsRequested: 1000, pairsRead: pairs, read1Reads: pairs, read2Reads: pairs,
                              namesEqual: names ?? pairs, withinOneMismatch: near, exact: exact, distinctUMIs: distinct)
    }

    // MARK: The argv

    func testArgvRoundTripsAndNamesEveryValue() throws {
        let arguments = Self.arguments(choice: .even)
        XCTAssertEqual(arguments.argv, [
            "umi-layout-check", "--read1", "inputs/pair1_R1.fastq.gz", "--read2", "inputs/pair1_R2.fastq.gz",
            "--decompressor", "pigz", "--kit", Self.kit, "--motif", "ATCAATC", "--umi-length", "16", "--umi-read", "1",
            "--pairs", "1000", "--choice", "even", "--within-one-mismatch-pass", "90", "--exact-warn", "90",
            "--distinct-fail", "50", "--distinct-warn", "80", "--output", "umi-check/layout-check.json",
        ])
        XCTAssertEqual(try UMILayoutCheck.Arguments(argv: arguments.argv), arguments)
        XCTAssertEqual(try UMILayoutCheck.Arguments(argv: Array(arguments.argv.dropFirst())), arguments)
    }

    /// ARCH-UMI-CHECKER item 3: the checker has no defaults, so a missing or unknown flag is a usage error.
    func testMissingOrUnknownFlagIsAUsageError() {
        var argv = Self.arguments().argv
        argv.removeSubrange(argv.firstIndex(of: "--exact-warn")!...argv.firstIndex(of: "--exact-warn")! + 1)
        XCTAssertThrowsError(try UMILayoutCheck.Arguments(argv: argv)) { error in
            XCTAssertEqual((error as? UMILayoutCheck.UsageError)?.message, "--exact-warn is missing")
        }
        XCTAssertThrowsError(try UMILayoutCheck.Arguments(argv: Self.arguments().argv + ["--seed", "1"])) { error in
            XCTAssertEqual((error as? UMILayoutCheck.UsageError)?.message, "unknown option --seed")
        }
        XCTAssertThrowsError(try UMILayoutCheck.Arguments(argv: Self.arguments().argv.map { $0 == "first" ? "random" : $0 }))
        XCTAssertThrowsError(try UMILayoutCheck.Arguments(argv: Self.arguments().argv.map { $0 == "16" ? "0" : $0 }))
    }

    // MARK: The rule on in-memory pairs

    /// ARCH-UMI-CHECKER's fixture: 870 exact, 60 within one mismatch, 70 with none, 600 distinct UMIs. The distinct
    /// share divides by the pairs read, 600 of 1,000, and among the exact pairs it is 600 of 870, cut down to 68.9%.
    func testArchFixtureCountsOnThePairsRead() {
        var tally = UMILayoutCheck.Tally(motif: "ATCAATC", umiLength: 16)
        for pair in UMILayoutCheckFixture.archPairs() {
            tally.add(header1: Array(pair.header1.utf8), umiRead: Array(pair.read1.utf8), header2: Array(pair.header2.utf8))
        }
        XCTAssertEqual(tally.pairsRead, 1000)
        XCTAssertEqual(tally.namesEqual, 1000)
        XCTAssertEqual(tally.withinOneMismatch, 930)
        XCTAssertEqual(tally.exact, 870)
        XCTAssertEqual(tally.distinctUMIs, 600)
        let report = UMILayoutCheck.Report(counts: Self.counts(near: 930, exact: 870, distinct: 600), arguments: Self.arguments())
        XCTAssertEqual(report.verdict, .warned)
        XCTAssertEqual(report.reasons.map(\.code), [.exactUnderBar, .distinctUnderWarnBar])
        XCTAssertEqual(report.shares.map(\.percent), ["100.0", "93.0", "87.0", "60.0", "68.9"])
        XCTAssertEqual(report.shares.map(\.denominator), [.pairsRead, .pairsRead, .pairsRead, .pairsRead, .exact])
        XCTAssertTrue(report.words.contains("Warning: 600 of 1,000 pairs read (60.0%) hold a distinct UMI, under 80%. Among the 870 pairs with the exact motif, 68.9% of UMIs are distinct, so many reads share a UMI."), report.words)
    }

    /// The name is the header's first word cut at the first `/`, so `/1` and `/2` and a comment never differ.
    func testNamesCompareTheFirstWordCutAtTheSlash() {
        var tally = UMILayoutCheck.Tally(motif: "ATCAATC", umiLength: 16)
        tally.add(header1: Array("@r1/1 1:N:0:A".utf8), umiRead: Array("ATCAATC".utf8), header2: Array("@r1/2 2:N:0:A".utf8))
        tally.add(header1: Array("@r2 x".utf8), umiRead: Array("ATCAATC".utf8), header2: Array("@r3 x".utf8))
        XCTAssertEqual(tally.namesEqual, 1)
    }

    /// BIO-UMI-SHARE item 6: a 20-base Read 1 that holds the motif counts within one mismatch, as `layout.py` does, but
    /// neither exact nor as a UMI, since extraction needs the motif and the whole UMI (23 bases).
    func testShortReadOneCountsNearButNotExact() {
        var tally = UMILayoutCheck.Tally(motif: "ATCAATC", umiLength: 16)
        tally.add(header1: Array("@a".utf8), umiRead: Array("ATCAATCACGTACGTACGTA".utf8), header2: Array("@a".utf8))
        tally.add(header1: Array("@b".utf8), umiRead: Array("ATCAAT".utf8), header2: Array("@b".utf8))
        tally.add(header1: Array("@c".utf8), umiRead: Array("TTCAATCACGTACGTACGTACGTAAAA".utf8), header2: Array("@c".utf8))
        XCTAssertEqual(tally.pairsRead, 3)
        XCTAssertEqual(tally.withinOneMismatch, 2)
        XCTAssertEqual(tally.exact, 0)
        XCTAssertEqual(tally.distinctUMIs, 0)
    }

    /// The spread choice: `pairs` indices evenly spaced through the file, every pair when it holds fewer.
    func testEvenChoiceSpreadsThePairsThroughTheFile() {
        XCTAssertEqual(UMILayoutCheck.Choice.even.indices(total: 10, pairs: 4), [0, 2, 5, 7])
        XCTAssertEqual(UMILayoutCheck.Choice.even.indices(total: 3, pairs: 1000), [0, 1, 2])
        XCTAssertEqual(UMILayoutCheck.Choice.first.indices(total: 10, pairs: 4), [0, 1, 2, 3])
        XCTAssertEqual(UMILayoutCheck.Choice.even.indices(total: 15_969_450, pairs: 1000).count, 1000)
        XCTAssertEqual(UMILayoutCheck.Choice.even.indices(total: 15_969_450, pairs: 1000).last, 15_953_480)
    }
}

// MARK: The words of BIO-UMI-SHARE, whose numbers, denominators and causes bind

extension UMILayoutCheckTests {
    /// C106 (SRR28155077), BIO-UMI-SHARE item 13: 840 of 1,000 (84.0%) and 840 of 879 among exact (95.5%, cut down).
    func testC106PassesWithTheExactWarning() {
        let report = UMILayoutCheck.Report(counts: Self.counts(near: 938, exact: 879, distinct: 840), arguments: Self.arguments())
        XCTAssertEqual(report.verdict, .warned)
        XCTAssertEqual(report.shares.last?.percent, "95.5")
        XCTAssertEqual(report.shares[3].percent, "84.0")
        XCTAssertEqual(report.words, """
        UMI layout check passed: 938 of 1,000 pairs read (93.8%) start within one mismatch of ATCAATC, 879 (87.9%) exactly, and 840 (84.0%) hold a distinct UMI.
        Warning: Read 1 starts with ATCAATC exactly in 879 of 1,000 pairs read (87.9%), under 90%. UMI extraction keeps only exact matches, so pairs with a one-base error in the motif get no UMI and are left out of the counts. The per-sample report gives the share of the whole run that extraction kept.
        """)
    }

    /// BIO-UMI-SHARE item 13, EX-UMI-M1-BIO should-fix 1: the bars applied to the 33 rows of C9's layout.tsv (the counts
    /// `layout.py` gives on the first 1,000 pairs of each run) pass 32 runs and warn on SRR28155077 (C106), on the exact
    /// share only. A row is (run, exact, near, distinct), columns 4, 5 and 6 of rnaseq/work/gse163196/layout.tsv.
    func testC9LayoutRowsGiveTheRulingsVerdicts() {
        let rows: [(run: String, exact: Int, near: Int, distinct: Int)] = [
            ("SRR13319534", 958, 970, 929), ("SRR13319535", 942, 968, 919), ("SRR13319536", 942, 959, 920),
            ("SRR13319537", 945, 975, 881), ("SRR13319538", 947, 965, 900), ("SRR13319539", 933, 956, 913),
            ("SRR13319540", 924, 963, 878), ("SRR13319541", 945, 972, 886), ("SRR13319542", 941, 967, 890),
            ("SRR13319543", 935, 963, 892), ("SRR13319544", 945, 967, 887), ("SRR13319545", 946, 969, 895),
            ("SRR13319546", 946, 978, 899), ("SRR28155078", 933, 956, 913), ("SRR28155079", 924, 963, 878),
            ("SRR28155080", 945, 972, 886), ("SRR28155081", 941, 967, 890), ("SRR28155082", 935, 963, 892),
            ("SRR28155083", 946, 969, 895), ("SRR28155084", 946, 978, 899), ("SRR28155085", 958, 970, 929),
            ("SRR28155086", 942, 968, 919), ("SRR28155087", 942, 959, 920), ("SRR28155088", 945, 975, 881),
            ("SRR28155089", 947, 965, 900), ("SRR28155066", 945, 964, 903), ("SRR28155069", 948, 970, 886),
            ("SRR28155070", 907, 951, 860), ("SRR28155071", 907, 958, 870), ("SRR28155072", 911, 971, 865),
            ("SRR28155073", 933, 947, 910), ("SRR28155074", 958, 981, 910), ("SRR28155077", 879, 938, 840),
        ]
        XCTAssertEqual(rows.count, 33)
        func percent(_ count: Int) -> String { "\(count / 10).\(count % 10)" }
        var verdicts: [String: Int] = [:]
        for row in rows {
            let report = UMILayoutCheck.Report(
                counts: Self.counts(near: row.near, exact: row.exact, distinct: row.distinct), arguments: Self.arguments())
            verdicts["\(report.verdict)", default: 0] += 1
            XCTAssertEqual(Array(report.shares.map(\.percent).prefix(4)),
                           ["100.0", percent(row.near), percent(row.exact), percent(row.distinct)], row.run)
            if row.run == "SRR28155077" {
                XCTAssertEqual(report.verdict, .warned, row.run)
                XCTAssertEqual(report.reasons.map(\.code), [.exactUnderBar], row.run)
            } else {
                XCTAssertEqual(report.verdict, .passed, row.run)
                XCTAssertTrue(report.reasons.isEmpty, row.run)
            }
        }
        XCTAssertEqual(verdicts, ["passed": 32, "warned": 1])
    }

    func testPassAtTheBarsIsNoWarning() {
        let report = UMILayoutCheck.Report(counts: Self.counts(near: 900, exact: 900, distinct: 800), arguments: Self.arguments())
        XCTAssertEqual(report.verdict, .passed)
        XCTAssertEqual(report.words, "UMI layout check passed: 900 of 1,000 pairs read (90.0%) start within one mismatch of ATCAATC, 900 (90.0%) exactly, and 800 (80.0%) hold a distinct UMI.")
        // A share just under a bar is cut down, so it never reads as the bar.
        let under = UMILayoutCheck.Report(counts: Self.counts(pairs: 1001, near: 1001, exact: 900, distinct: 1000), arguments: Self.arguments())
        XCTAssertEqual(under.verdict, .warned)
        XCTAssertTrue(under.words.contains("900 of 1,001 pairs read (89.9%), under 90%"), under.words)
    }

    func testDistinctWarningNamesItsCause() {
        let motif = UMILayoutCheck.Report(counts: Self.counts(near: 990, exact: 760, distinct: 720), arguments: Self.arguments())
        XCTAssertTrue(motif.words.contains("Warning: 720 of 1,000 pairs read (72.0%) hold a distinct UMI, under 80%, because only 760 (76.0%) start with ATCAATC exactly. Among those, 94.7% of UMIs are distinct."), motif.words)
        let umi = UMILayoutCheck.Report(counts: Self.counts(near: 990, exact: 940, distinct: 720), arguments: Self.arguments())
        XCTAssertEqual(umi.reasons.map(\.code), [.distinctUnderWarnBar])
        XCTAssertTrue(umi.words.hasSuffix("Warning: 720 of 1,000 pairs read (72.0%) hold a distinct UMI, under 80%. Among the 940 pairs with the exact motif, 76.5% of UMIs are distinct, so many reads share a UMI. The library may hold few molecules, or the 16 bases after ATCAATC may not be a random UMI. Check the \(Self.kit) preset against the kit's read layout."), umi.words)
    }

    /// BIO-UMI-SHARE item 11: fewer pairs than requested is no failure, and the shares divide by the pairs read.
    func testFewerPairsThanRequestedDivideByThePairsRead() {
        let report = UMILayoutCheck.Report(counts: Self.counts(pairs: 400, near: 400, exact: 380, distinct: 360), arguments: Self.arguments())
        XCTAssertEqual(report.verdict, .passed)
        XCTAssertEqual(report.words, "UMI layout check passed: 400 of 400 pairs read (100.0%) start within one mismatch of ATCAATC, 380 (95.0%) exactly, and 360 (90.0%) hold a distinct UMI.")
    }

    func testFailuresSayWhatToTry() {
        let motif = UMILayoutCheck.Report(counts: Self.counts(near: 612, exact: 600, distinct: 590), arguments: Self.arguments())
        XCTAssertEqual(motif.verdict, .failed)
        XCTAssertEqual(motif.words, "UMI layout check failed: 612 of 1,000 pairs read (61.2%) start within one mismatch of ATCAATC, under the 90% the \(Self.kit) preset needs. These reads may come from another kit, or Read 1 and Read 2 may be swapped. Try: check the sample sheet's kit column, and that the file named Read 1 holds the UMI. This sample gets no UMI counts.")
        let oneBase = UMILayoutCheck.Report(counts: Self.counts(near: 962, exact: 12, distinct: 12), arguments: Self.arguments())
        XCTAssertEqual(oneBase.words, "UMI layout check failed: 12 of 1,000 pairs read (1.2%) hold a distinct UMI, under 50%, because only 12 (1.2%) start with ATCAATC exactly while 962 (96.2%) are within one mismatch. The kit's fixed sequence may differ from the preset's by one base. Try: check that the \(Self.kit) preset matches the kit. This sample gets no UMI counts.")
        let repeats = UMILayoutCheck.Report(counts: Self.counts(near: 950, exact: 910, distinct: 31), arguments: Self.arguments())
        XCTAssertEqual(repeats.words, "UMI layout check failed: 31 of 1,000 pairs read (3.1%) hold a distinct UMI, under 50%. Among the 910 pairs with the exact motif, 3.4% of UMIs are distinct, so the 16 bases after ATCAATC are not a random UMI. Try: check the UMI's position and length in the \(Self.kit) preset. This sample gets no UMI counts.")
        let names = UMILayoutCheck.Report(counts: Self.counts(names: 963, near: 1000, exact: 1000, distinct: 990), arguments: Self.arguments())
        XCTAssertEqual(names.words, "UMI layout check failed: read names differ between Read 1 and Read 2 in 37 of 1,000 pairs read. The two files are not mates in the same order. Try: import the pair again from its source. This sample gets no UMI counts.")
        var short = Self.counts(pairs: 640, near: 640, exact: 640, distinct: 600)
        short.read1Reads = 1000
        let mate = UMILayoutCheck.Report(counts: short, arguments: Self.arguments())
        XCTAssertEqual(mate.verdict, .failed)
        XCTAssertEqual(mate.words, "UMI layout check failed: Read 1 gave 1,000 reads and Read 2 gave 640 of the 1,000 pairs to read. The two files are not a whole pair. This sample gets no UMI counts.")
        let none = UMILayoutCheck.Report(counts: Self.counts(pairs: 0, near: 0, exact: 0, distinct: 0), arguments: Self.arguments())
        XCTAssertEqual(none.verdict, .failed)
        XCTAssertEqual(none.reasons.map(\.code), [.noPairRead])
    }
}

/// ARCH-UMI-CHECKER's fixture as pairs in memory: 870 exact, 60 with one mismatch, 70 with none, and 600 distinct UMIs
/// among the exact pairs.
enum UMILayoutCheckFixture {
    struct Pair {
        var header1: String
        var read1: String
        var header2: String
        var read2: String
    }

    static func umi(_ n: Int) -> String {
        var value = n &* 2_654_435_761 & 0xFFFF_FFFF
        return String((0..<16).map { _ -> Character in
            defer { value >>= 2 }
            return Array("ACGT")[value & 3]
        })
    }

    static func archPairs() -> [Pair] {
        (0..<1000).map { i in
            let motif = i < 870 ? "ATCAATC" : i < 930 ? "ATCTATC" : "GGGCCCA"
            let read1 = motif + umi(i < 870 ? i % 600 : 600 + i) + "TTTTTTTTTTTTTTTTTT"
            return Pair(header1: "@SRR0.\(i + 1) \(i + 1)/1", read1: read1, header2: "@SRR0.\(i + 1) \(i + 1)/2",
                        read2: "ACGTTGCAACGTTGCAACGTTGCAACGTTGCAACGTTGCA")
        }
    }
}
