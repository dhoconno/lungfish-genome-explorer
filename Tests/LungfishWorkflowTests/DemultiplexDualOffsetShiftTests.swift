// DemultiplexDualOffsetShiftTests.swift - A placed read stays only in the row whose anchored pair fits it at the fewest errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-DUAL-OFFSET-SHIFT (ruling BIO-OFFSET-SHIFT items 2 and 3, S1). At Both Ends with no sample sheet and a 5' or 3'
// Distance above 0, a Custom Definition of dual indexes writes a line for each pair of offsets, `^N{a}F...BN{b}$`. Cutadapt
// ranks the lines that match a read by score and scores each N as a matched base, so a line of another row further in, its
// barcode completed by insert or flank bases, beat the right row's line at the read ends and moved the read into another
// sample with no word. A read now stays in a row only when no other row's pair fits it at the same or fewer errors, and a
// read that two rows fit equally goes to Unassigned and is counted. The count is read by the label of the result's field,
// so the file builds at the base. Each test runs Cutadapt.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexDualOffsetShiftTests: XCTestCase {
    var project: URL!
    var dir: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexDualOffsetShiftTests-\(UUID().uuidString).lungfish", isDirectory: true)
        dir = project.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    typealias Row = DemultiplexDualFormTests.Row
    typealias Read = DemultiplexDualFormTests.Read

    static func rc(_ sequence: String) -> String { PlatformAdapters.reverseComplement(sequence) }

    /// Rows 1 and 5 of the swap layout of BIO-DUAL-FORM, which share the first barcode.
    static let x1x5: [Row] = [("X-1", "TGGGCGAA", "AGGAGTTA"), ("X-5", "TGGGCGAA", "GTAAGGAG")]

    /// Reads of `SCR/scratch/BIO-DUAL-FORM/made-swap-seen.fastq` as BIO-OFFSET-SHIFT Q1 names them. Each carries X-1's pair
    /// at the read ends, and its insert ends with the bases that complete X-5's second barcode further in: `GTA` for read
    /// 9, so X-5 fits it with no error, and `TTA` for read 6, one base from it.
    static let seenF0x9: Read = ("X-1|seen|F0|9", "TGGGCGAATTGCAGATACCTCTGCTTCTTAAATGTCGGCCAGCGTTTGAAGCTAAAGTCTCAGTCCACCCGGCCGAGGGCAGTATCTGAGTTACCTGTGTGTCGTGTAAGGAGTTA")
    static let seenR0x9: Read = ("X-1|seen|R0|9", "TAACTCCTTACACGACACACAGGTAACTCAGATACTGCCCTCGGCCGGGTGGACTGAGACTTTAGCTTCAAACGCTGGCCGACATTTAAGAAGCAGAGGTATCTGCAATTCGCCCA")
    static let seenF0x6: Read = ("X-1|seen|F0|6", "TGGGCGAAGCTCGCAGCGGCAATATCACTCCCGAGTTTAAAAGGCGGAAGCGCCCGGTTCCAGTGGGGTCCCATTGGTGGATCTTATGTGCGATATAAAATCTTGTTAAGGAGTTA")
    static let seenR0x6: Read = ("X-1|seen|R0|6", "TAACTCCTTAACAAGATTTTATATCGCACATAAGATCCACCAATGGGACCCCACTGGAACCGGGCGCTTCCGCCTTTTAAACTCGGGAGTGATATTGCCGCTGCGAGCTTCGCCCA")

    /// Five reads of each row of `rows` on each strand, the pair 3 bases in at each end behind `CCC`, so no other row's
    /// pair can sit within 3 bases of the ends. Every rule places them in their own rows.
    static func fillers(_ rows: [Row]) -> [Read] {
        var bases = DemultiplexDualFormTests.Bases()
        return rows.flatMap { row in
            (0..<5).flatMap { index -> [Read] in
                let forward = "CCC" + row.first + bases.next(60) + row.second + "CCC"
                return [("\(row.name)|F3-\(index)", forward), ("\(row.name)|R3-\(index)", rc(forward))]
            }
        }
    }

    /// The rows of nextera-xt-v2 (`IlluminaBarcodeKits.swift:363-397`), as a Custom Definition lists them.
    static let nextera: [Row] = BarcodeKitRegistry.nexteraXTv2.barcodes.map { ($0.id, $0.i7Sequence, $0.i5Sequence ?? "") }

    /// Reads of `row` with the ONT native inner flanks and the pair at the read ends: first + `CAGCACCT` + insert +
    /// `AGGTGCTG` + second, five on each strand (BIO-OFFSET-SHIFT Q2).
    static func flankedReads(_ row: Row, seed: UInt64) -> [Read] {
        var bases = DemultiplexDualFormTests.Bases(state: seed)
        return (0..<5).flatMap { index -> [Read] in
            let forward = row.first + "CAGCACCT" + bases.next(60) + "AGGTGCTG" + row.second
            return [("\(row.name)|F0-\(index)", forward), ("\(row.name)|R0-\(index)", rc(forward))]
        }
    }

    /// Two reads of each row on each strand, outer flank + first + `CAGCACCT` + insert + `AGGTGCTG` + second + outer
    /// flank, the outer flanks the last `outer` bases of `AAGGTTAA` and the first `outer` bases of `TTAACCTT` (BIO-OFFSET-SHIFT
    /// Q2, the ONT native barcode flanks).
    static func ontFlankedReads(_ rows: [Row], outer: Int) -> [Read] {
        var bases = DemultiplexDualFormTests.Bases()
        let before = String("AAGGTTAA".suffix(outer)), after = String("TTAACCTT".prefix(outer))
        return rows.flatMap { row in
            (0..<2).flatMap { index -> [Read] in
                let forward = before + row.first + "CAGCACCT" + bases.next(60) + "AGGTGCTG" + row.second + after
                return [("\(row.name)|F\(outer)-\(index)", forward), ("\(row.name)|R\(outer)-\(index)", rc(forward))]
            }
        }
    }

    func writeFASTQ(_ reads: [Read]) throws -> URL {
        let url = dir.appendingPathComponent("reads-\(UUID().uuidString).fastq")
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The definition "K" of `rows`, loaded as the command loads a Custom Definition.
    func kit(_ rows: [Row]) throws -> BarcodeKitDefinition {
        let csv = dir.appendingPathComponent("K-\(UUID().uuidString).csv")
        let text = "id,i7_sequence,i5_sequence\n" + rows.map { "\($0.name),\($0.first),\($0.second)\n" }.joined()
        try text.write(to: csv, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: csv, name: "K")
        XCTAssertEqual(kit.pairingMode, .fixedDual)
        XCTAssertEqual(kit.platform, .unknown)
        return kit
    }

    struct Outcome {
        /// The reads of each published sample, by name, with the bases its file holds.
        let placed: [String: [Read]]
        let unassigned: [String]
        let unassignedCount: Int
        /// The result's `ambiguousReads`, or "none" when the result has no such field or it is nil.
        let ambiguous: String
        let commandLine: String

        /// The row a read landed in, "Unassigned", or "missing".
        func row(of name: String) -> String {
            if unassigned.contains(name) { return "Unassigned" }
            return placed.first { $0.value.contains { $0.name == name } }?.key ?? "missing"
        }

        func sequence(of name: String) -> String? {
            placed.values.joined().first { $0.name == name }?.sequence
        }

        /// The reads that landed in a row that is not the row their name starts with.
        var wrong: [String] {
            placed.flatMap { row, reads in reads.filter { !$0.name.hasPrefix(row + "|") }.map { "\($0.name) in \(row)" } }.sorted()
        }
    }

    static func ambiguous(_ result: DemultiplexResult) -> String {
        guard let field = Mirror(reflecting: result).children.first(where: { $0.label == "ambiguousReads" }),
              let count = Mirror(reflecting: field.value).children.first?.value else { return "none" }
        return String(describing: count)
    }

    func records(_ url: URL) async throws -> [Read] {
        var reads: [Read] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            reads.append((record.identifier, record.sequence))
        }
        return reads
    }

    func run(_ rows: [Row], _ input: URL, distance: Int, errorRate: Double) async throws -> Outcome {
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: input, barcodeKit: try kit(rows), outputDirectory: output, barcodeLocation: .bothEnds,
            errorRate: errorRate, maxDistanceFrom5Prime: distance, maxDistanceFrom3Prime: distance,
            trimBarcodes: true, threads: 1
        )
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        var placed: [String: [Read]] = [:]
        for barcode in result.manifest.barcodes {
            let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), barcode.barcodeID)
            placed[barcode.barcodeID] = try await records(fastq)
        }
        var unassigned: [String] = []
        if let bundle = result.unassignedBundleURL, let fastq = FASTQBundle.resolvePrimaryFASTQURL(for: bundle) {
            unassigned = try await records(fastq).map(\.name)
        }
        return Outcome(
            placed: placed, unassigned: unassigned, unassignedCount: result.manifest.unassigned.readCount,
            ambiguous: Self.ambiguous(result), commandLine: result.manifest.parameters.commandLine ?? ""
        )
    }

    func run(_ rows: [Row], _ reads: [Read], distance: Int, errorRate: Double) async throws -> Outcome {
        try await run(rows, try writeFASTQ(reads), distance: distance, errorRate: errorRate)
    }

    func report(_ label: String, _ outcome: Outcome, _ names: [String]) {
        let rows = names.map { "\($0) -> \(outcome.row(of: $0))" }.joined(separator: ", ")
        print("OFFSETSHIFT \(label): \(rows); wrong \(outcome.wrong.count); unassigned \(outcome.unassignedCount); "
              + "ambiguousReads \(outcome.ambiguous)")
    }

    func assertFillersInTheirRows(_ rows: [Row], _ outcome: Outcome, _ label: String) {
        for row in rows {
            let names = (outcome.placed[row.name] ?? []).map(\.name).filter { $0.contains("|F3-") || $0.contains("|R3-") }
            XCTAssertEqual(names.count, 10, "\(label): \(row.name)")
        }
        XCTAssertEqual(outcome.wrong, [], label)
    }

    // MARK: - (a) Two rows fit with no error

    /// X-1's reads 9 at 3/3 and error 0: X-1's pair sits at the read ends with no error, and X-5's line
    /// `^TGGGCGAA...GTAAGGAGN{3}$` fits the insert's `GTA` + `AGGAG` with no error either, scoring 19 over 16. At the base
    /// both reads land in X-5. Two rows fit them at their fewest errors, so they go to Unassigned and are counted.
    func testAReadThatTwoRowsFitWithNoErrorGoesToUnassignedAndIsCounted() async throws {
        let named = [Self.seenF0x9, Self.seenR0x9]
        let outcome = try await run(Self.x1x5, named + Self.fillers(Self.x1x5), distance: 3, errorRate: 0)
        report("(a) 3/3 e 0", outcome, named.map(\.name))
        for read in named {
            XCTAssertEqual(outcome.row(of: read.name), "Unassigned", "\(read.name) is not X-5's read")
        }
        XCTAssertEqual(outcome.unassignedCount, 2, "the Unassigned count holds the two reads")
        XCTAssertEqual(outcome.ambiguous, "2")
        assertFillersInTheirRows(Self.x1x5, outcome, "(a)")
    }

    // MARK: - (b) One row fits with fewer errors

    /// X-1's reads 6 at 3/3 and error 0.15: X-1 fits them with no error, and X-5 fits the insert's `TTA` + `AGGAG` with one
    /// mismatch, scoring 17 over 16. At the base both land in X-5. X-1 fits them at fewer errors, so they stay in X-1,
    /// trimmed as X-1's line at the read ends trims them (the manager's answer, BIO-OFFSET-SHIFT item 2).
    func testAReadThatItsOwnRowFitsAtFewerErrorsStaysInItsOwnRow() async throws {
        let named = [Self.seenF0x6, Self.seenR0x6]
        let outcome = try await run(Self.x1x5, named + Self.fillers(Self.x1x5), distance: 3, errorRate: 0.15)
        report("(b) 3/3 e 0.15", outcome, named.map(\.name))
        for read in named {
            XCTAssertNotEqual(outcome.row(of: read.name), "X-5", read.name)
            XCTAssertEqual(outcome.row(of: read.name), "X-1", read.name)
            XCTAssertEqual(outcome.sequence(of: read.name), String(read.sequence.dropFirst(8).dropLast(8)), read.name)
        }
        XCTAssertEqual(outcome.unassignedCount, 0)
        XCTAssertEqual(outcome.ambiguous, "0")
        assertFillersInTheirRows(Self.x1x5, outcome, "(b)")
    }

    // MARK: - (c) The made swap file in primer form

    /// The 480 reads of `made-swap-primer.fastq` (BIO-DUAL-FORM) on the 12 rows of the swap layout at 3/3 and 0.15, read in
    /// the form DEMUX-DUAL-FORM chooses. At the base 13 reads land in another row (BIO-OFFSET-SHIFT Q1). None does now, and
    /// at most 2 go to Unassigned.
    func testTheMadeSwapFileInPrimerFormPutsNoReadInAnotherRow() async throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let input = tests.appendingPathComponent("Fixtures/demux-dual-offset-shift/made-swap-primer.fastq")
        let outcome = try await run(DemultiplexDualFormTests.swap, input, distance: 3, errorRate: 0.15)
        report("(c) 3/3 e 0.15", outcome, [])
        print("OFFSETSHIFT (c) wrong: \(outcome.wrong)")
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertLessThanOrEqual(outcome.unassignedCount, 2)
        XCTAssertEqual(outcome.ambiguous, String(outcome.unassignedCount), "each read in Unassigned is one two rows fit")
        XCTAssertEqual(outcome.placed.values.map(\.count).reduce(0, +) + outcome.unassignedCount, 480)
    }

    // MARK: - (d) nextera-xt-v2 with real inner flanks

    /// The 84 rows of nextera-xt-v2 as a Custom Definition at 4/4 and 0.15, on reads with the ONT native inner flanks and
    /// the pair at the read ends. N704's `TCCTGAGC` is N705's `TCCT` + `GAGC`, and the flank `CAGCACCT` gives `TCCTCAGC`,
    /// one mismatch 4 bases in, so N704-S502's line scored 18 over 16 and took every N705-S502 read at the base
    /// (BIO-OFFSET-SHIFT Q2). N705-S502 fits them with no error, so they land in N705-S502, trimmed as its line trims them,
    /// and N704-S502's own reads stay in N704-S502.
    func testNexteraReadsWithRealFlanksLandInTheirOwnRow() async throws {
        let n705 = try XCTUnwrap(Self.nextera.first { $0.name == "N705-S502" })
        let n704 = try XCTUnwrap(Self.nextera.first { $0.name == "N704-S502" })
        XCTAssertEqual(Self.nextera.count, 84)
        let moved = Self.flankedReads(n705, seed: 0x705)
        let own = Self.flankedReads(n704, seed: 0x704)
        let outcome = try await run(Self.nextera, moved + own, distance: 4, errorRate: 0.15)
        report("(d) 4/4 e 0.15", outcome, (moved + own).map(\.name))
        for read in moved {
            XCTAssertEqual(outcome.row(of: read.name), "N705-S502", read.name)
            XCTAssertEqual(outcome.sequence(of: read.name), String(read.sequence.dropFirst(8).dropLast(8)), read.name)
        }
        for read in own {
            XCTAssertEqual(outcome.row(of: read.name), "N704-S502", read.name)
        }
        XCTAssertEqual(outcome.unassignedCount, 0)
        XCTAssertEqual(outcome.ambiguous, "0")
    }

    // MARK: - (e) What stays

    /// The swap layout with the ONT native outer flanks as long as the distance, 3 at 3/3 and 8 at 8/8, at error 0 and
    /// 0.15 (BIO-OFFSET-TIES items 1 and 2). The flank `TTA` completes X-1's `AGGAGTTA` behind X-5's `GTAAGGAG`, and Y-1's
    /// behind Y-5's, so X-1 fits those reads with no error at offset 0 as X-5 does at the flank's length. Two rows fit them
    /// at the same fewest errors, so the 8 reads of X-5 and Y-5 (both strands) go to Unassigned and are counted, and the
    /// other 40 land in their own rows (40/0/8). Cutadapt's rank kept the 8 in X-5 and Y-5 (48/0/0), the rank this replaces.
    func testReadsWithAnOuterFlankAsLongAsTheDistanceTieAtTwoRowsAndGoToUnassigned() async throws {
        for (outer, errorRate) in [(3, 0.0), (3, 0.15), (8, 0.0), (8, 0.15)] {
            let label = "(e) \(outer)/\(outer) e \(errorRate)"
            let reads = Self.ontFlankedReads(DemultiplexDualFormTests.swap, outer: outer)
            XCTAssertEqual(reads.count, 48)
            let outcome = try await run(DemultiplexDualFormTests.swap, reads, distance: outer, errorRate: errorRate)
            report(label, outcome, [])
            let tied = ["X-5", "Y-5"].flatMap { row in
                ["F", "R"].flatMap { strand in (0..<2).map { "\(row)|\(strand)\(outer)-\($0)" } }
            }
            XCTAssertEqual(outcome.wrong, [], label)
            XCTAssertEqual(outcome.unassigned.sorted(), tied.sorted(), label)
            XCTAssertEqual(outcome.unassignedCount, 8, label)
            XCTAssertEqual(outcome.ambiguous, "8", label)
            XCTAssertEqual(outcome.placed.values.map(\.count).reduce(0, +), 40, label)
        }
    }

    /// A run at 0/0 stays as it was: the named reads at the read ends land in X-1 trimmed to their inserts, the fillers 3
    /// bases in go to Unassigned whole, the result has no count and Cutadapt's arguments are the base's.
    func testARunAtNoDistanceStaysAsItWas() async throws {
        let named = [Self.seenF0x9, Self.seenR0x9, Self.seenF0x6, Self.seenR0x6]
        // A sample's file holds the reads its forward lines placed, then those of the other strand.
        let coalesced = [Self.seenF0x9, Self.seenF0x6, Self.seenR0x9, Self.seenR0x6]
        for errorRate in [0.0, 0.15] {
            let label = "(e) 0/0 e \(errorRate)"
            let outcome = try await run(Self.x1x5, named + Self.fillers(Self.x1x5), distance: 0, errorRate: errorRate)
            report(label, outcome, named.map(\.name))
            XCTAssertEqual(outcome.placed.keys.sorted(), ["X-1"], label)
            XCTAssertEqual(outcome.placed["X-1"]?.map(\.name), coalesced.map(\.name), label)
            XCTAssertEqual(outcome.placed["X-1"]?.map(\.sequence), coalesced.map { String($0.sequence.dropFirst(8).dropLast(8)) }, label)
            XCTAssertEqual(outcome.unassignedCount, 20, label)
            XCTAssertEqual(outcome.unassigned, Self.fillers(Self.x1x5).map(\.name), label)
            XCTAssertEqual(outcome.ambiguous, "none", label)
            XCTAssertFalse(outcome.commandLine.contains("--info-file"), label)
        }
    }

    // MARK: - An indel is one error

    /// The check counts a base lost from or gained inside a barcode as one error when the run allows indels, as Cutadapt's
    /// line does, and finds no fit at e 0.15 when it does not (`--no-indels`). X-1's pair alone, offsets up to 3 as the
    /// writer's lines carry them (BIO-OFFSET-SHIFT item 2). No Cutadapt run.
    func testTheCheckCountsALostOrGainedBaseAsOneErrorOnlyWhenIndelsAreAllowed() throws {
        let lines = ">X-1\n^N{3}TGGGCGAA...AGGAGTTAN{3}$\n"
        let insert = String(repeating: "ACGTTGCA", count: 6)
        let reads = [
            Array(("TGGGCGAA" + insert + "AGGAGTA").utf8),    // the second barcode lost a T
            Array(("TGGGCGAA" + insert + "AGGAGGTTA").utf8),  // and gained a G
        ]
        for (indels, errors) in [(true, 1), (false, nil)] as [(Bool, Int?)] {
            let fit = try XCTUnwrap(AnchoredOffsetFit(adapterFASTA: lines, rowOf: { $0 }, errorRate: 0.15, indels: indels))
            for read in reads {
                var search = AnchoredOffsetFit.Search(fit)
                switch search.call(read) {
                case .one(_, let found, _): XCTAssertEqual(found, errors, "indels \(indels)")
                case .none: XCTAssertNil(errors, "indels \(indels)")
                default: XCTFail("one row cannot tie")
                }
            }
        }
    }

    // MARK: - A run that keeps trim positions

    /// The trim positions of a run kept for a chained step: the read the check moved to X-1 is listed in X-1 trimmed as
    /// X-1's line at the read ends trims it, the reads it sent to Unassigned are listed in no sample, and a read that
    /// stayed keeps Cutadapt's trims (BIO review of DEMUX-DUAL-OFFSET-SHIFT, SF2).
    func testAMovedAndATiedReadChangeTheTrimPositionsOfTheRunThatKeepsThem() async throws {
        let named = [Self.seenF0x9, Self.seenR0x9, Self.seenF0x6, Self.seenR0x6]
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: try writeFASTQ(named + Self.fillers(Self.x1x5)), barcodeKit: try kit(Self.x1x5),
            outputDirectory: output, barcodeLocation: .bothEnds, errorRate: 0.15, maxDistanceFrom5Prime: 3,
            maxDistanceFrom3Prime: 3, trimBarcodes: true, threads: 1, captureTrimsForChaining: true
        )
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        var trims: [String: [String: (Int, Int)]] = [:]
        for barcode in result.manifest.barcodes {
            let file = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
                .appendingPathComponent(FASTQBundle.trimPositionFilename)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("read_id") {
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count >= 4, let start = Int(fields[2]), let end = Int(fields[3]) else { continue }
                trims[barcode.barcodeID, default: [:]][fields[0]] = (start, end)
            }
        }
        print("OFFSETSHIFT trims: \(trims.mapValues { $0.count }), ambiguousReads \(Self.ambiguous(result))")
        for name in ["X-1|seen|F0|6", "X-1|seen|R0|6"] {
            XCTAssertEqual(trims["X-1"]?[name].map { [$0.0, $0.1] }, [8, 8], name)
            XCTAssertNil(trims["X-5"]?[name], name)
        }
        for name in ["X-1|seen|F0|9", "X-1|seen|R0|9"] {
            XCTAssertTrue(trims.values.allSatisfy { $0[name] == nil }, "\(name) is in Unassigned")
        }
        XCTAssertEqual(trims["X-1"]?["X-1|F3-0"].map { [$0.0, $0.1] }, [11, 11])
        XCTAssertEqual(Self.ambiguous(result), "2")
    }

    // MARK: - Paired input

    /// An interleaved file of two fragments whose first mate of fragment 1 two rows fit with no error at 3/3 and e 0: the
    /// run ends, every record is in one place, and the count names the one record the check set aside (BIO review of
    /// DEMUX-DUAL-OFFSET-SHIFT, SF3). Where the fragment lands is the mate pass's call, and the test prints it.
    func testAnInterleavedFragmentWhoseFirstMateTiesRunsToTheEndAndCountsItsRecords() async throws {
        let clean = Self.fillers(Self.x1x5).filter { $0.name.hasPrefix("X-1|F3-") }.map(\.sequence)
        let reads: [Read] = [
            ("X-1|pair-1/1", Self.seenF0x9.sequence), ("X-1|pair-1/2", clean[0]),
            ("X-1|pair-2/1", clean[1]), ("X-1|pair-2/2", clean[2]),
        ]
        let input = try writeFASTQ(reads)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(
                isClumpified: false, isCompressed: false, pairingMode: .interleaved,
                originalFilenames: [input.lastPathComponent]
            )),
            for: input
        )
        let outcome = try await run(Self.x1x5, input, distance: 3, errorRate: 0)
        report("paired 3/3 e 0", outcome, reads.map(\.name))
        let places = outcome.placed.values.flatMap { $0.map(\.name) } + outcome.unassigned
        XCTAssertEqual(Set(places).count, places.count, "no record is in two places")
        XCTAssertEqual(outcome.placed.values.map(\.count).reduce(0, +) + outcome.unassignedCount, 4)
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertEqual(outcome.ambiguous, "1")
    }
}
