// DemultiplexSingleOffsetShiftTests.swift - A read of a single-index kit stays only in the row that fits it at the fewest errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-SINGLE-OFFSET-SHIFT (ruling BIO-SINGLE-OFFSET items 1 to 4, BIO-OFFSET-TIES items 1 and 3, S1). With a 5' or
// 3' Distance above 0, a single-index kit with no sample sheet on a platform that reads one strand writes a line for each
// barcode and offset, `^N{a}X` at 5' End and Both Ends and `XN{b}$` at 3' End. Cutadapt ranks the lines that match a read
// by score and scores each N as a matched base, so a line of another row further in, its barcode completed by flank or
// insert bases, beat the right row's line at the read end and moved the read into another sample with no word. A read now
// stays in a row only when no other row fits it at the same or fewer errors, and a read that two rows fit equally goes to
// Unassigned and is counted. Each test runs Cutadapt.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexSingleOffsetShiftTests: XCTestCase {
    var project: URL!
    var dir: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexSingleOffsetShiftTests-\(UUID().uuidString).lungfish", isDirectory: true)
        dir = project.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    typealias Read = DemultiplexDualFormTests.Read

    /// The bases before and after the index of a TruSeq single-index read, the P7 flank (BIO-SINGLE-OFFSET Q2).
    static let truseqBefore = "CCAGTCAC"
    static let truseqAfter = "ATCTCGTATGCCGTCTTCTGCTTG"

    /// Two reads of each row of TruSeq Single Index Set A at each offset from 0 to 8: the last k bases of `CCAGTCAC`, the
    /// index, `ATCTCGTATGCCGTCTTCTGCTTG` and an insert (BIO-SINGLE-OFFSET Q2, the real flank). The name is
    /// `<row>|k<k>-<n>`, and the bases after the index are `afterIndex`.
    static func truseqReads() -> (reads: [Read], afterIndex: [String: String]) {
        var bases = DemultiplexDualFormTests.Bases()
        var reads: [Read] = []
        var afterIndex: [String: String] = [:]
        for barcode in BarcodeKitRegistry.truseqSingleA.barcodes {
            for k in 0...8 {
                for index in 0..<2 {
                    let name = "\(barcode.id)|k\(k)-\(index)"
                    let after = truseqAfter + bases.next(40)
                    reads.append((name, String(truseqBefore.suffix(k)) + barcode.i7Sequence + after))
                    afterIndex[name] = after
                }
            }
        }
        return (reads, afterIndex)
    }

    func writeFASTQ(_ reads: [Read]) throws -> URL {
        let url = dir.appendingPathComponent("reads-\(UUID().uuidString).fastq")
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The definition "K" with one sequence a row, loaded as the command loads a Custom Definition.
    func customKit(_ rows: [(name: String, sequence: String)]) throws -> BarcodeKitDefinition {
        let csv = dir.appendingPathComponent("K-\(UUID().uuidString).csv")
        try ("id,sequence\n" + rows.map { "\($0.name),\($0.sequence)\n" }.joined()).write(to: csv, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: csv, name: "K")
        XCTAssertEqual(kit.pairingMode, .singleEnd)
        XCTAssertFalse(kit.platform.readsCanBeReverseComplemented)
        return kit
    }

    struct Outcome {
        /// The reads of each published sample, by name, with the bases its file holds.
        let placed: [String: [Read]]
        /// The reads of Unassigned, with the bases its file holds.
        let unassigned: [Read]
        let unassignedCount: Int
        /// The result's `ambiguousReads`, nil when the run did not check its placed reads.
        let ambiguous: Int?
        let ends: DemultiplexingPipeline.SearchedEnds?

        /// The line of the Operations Panel row, its Log and the command's summary.
        var line: String? { DemultiplexingPipeline.ambiguousReadsLine(ambiguous ?? 0, ends: ends ?? .both) }

        /// The row a read landed in, "Unassigned", or "missing".
        func row(of name: String) -> String {
            if unassigned.contains(where: { $0.name == name }) { return "Unassigned" }
            return placed.first { $0.value.contains { $0.name == name } }?.key ?? "missing"
        }

        func sequence(of name: String) -> String? {
            (placed.values.joined() + unassigned).first { $0.name == name }?.sequence
        }

        /// The reads that landed in a row that is not the row their name starts with.
        var wrong: [String] {
            placed.flatMap { row, reads in reads.filter { !$0.name.hasPrefix(row + "|") }.map { "\($0.name) in \(row)" } }.sorted()
        }

        var placedCount: Int { placed.values.map(\.count).reduce(0, +) }
    }

    func records(_ url: URL) async throws -> [Read] {
        var reads: [Read] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            reads.append((record.identifier, record.sequence))
        }
        return reads
    }

    func run(
        _ kit: BarcodeKitDefinition, _ reads: [Read], location: BarcodeLocation, fivePrime: Int = 0, threePrime: Int = 0,
        errorRate: Double
    ) async throws -> Outcome {
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: try writeFASTQ(reads), barcodeKit: kit, outputDirectory: output, barcodeLocation: location,
            errorRate: errorRate, maxDistanceFrom5Prime: fivePrime, maxDistanceFrom3Prime: threePrime,
            trimBarcodes: true, threads: 1, engine: .cutadapt
        )
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        var placed: [String: [Read]] = [:]
        for barcode in result.manifest.barcodes {
            let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), barcode.barcodeID)
            placed[barcode.barcodeID] = try await records(fastq)
        }
        var unassigned: [Read] = []
        if let bundle = result.unassignedBundleURL, let fastq = FASTQBundle.resolvePrimaryFASTQURL(for: bundle) {
            unassigned = try await records(fastq)
        }
        return Outcome(
            placed: placed, unassigned: unassigned, unassignedCount: result.manifest.unassigned.readCount,
            ambiguous: result.ambiguousReads, ends: result.ambiguousReadsEnds
        )
    }

    func report(_ label: String, _ outcome: Outcome, _ names: [String]) {
        let rows = names.map { "\($0) -> \(outcome.row(of: $0))" }.joined(separator: ", ")
        print("SINGLEOFFSET \(label): \(rows); wrong \(outcome.wrong.count) \(outcome.wrong.prefix(16)); "
              + "unassigned \(outcome.unassignedCount); ambiguousReads \(outcome.ambiguous.map(String.init) ?? "nil")")
    }

    // MARK: - (a) and (b) The built-in TruSeq Single Index Set A at its real flank

    /// 5' Distance 8, the flank's length, at the default error rate 0.15. D701 `ATTACTCG` fits D703's reads with one indel
    /// 5 bases in, and D706 `GAATTCGT` fits D702's reads with one indel 6 bases in. At the base all 8 D703 reads at 0 to
    /// 3 bases in landed in D701, and all 6 D702 reads at 0 to 2 bases in landed in D706, since the line further in scored
    /// its N's. Their own rows fit them with no error, so they now land in D703 and D702, trimmed after their index as
    /// their own line trims them. Both Ends writes the 5' End lines, so it places them the same way.
    func testTruSeqReadsThatAnotherRowFitsFurtherInWithOneIndelLandInTheirOwnRows() async throws {
        let (reads, afterIndex) = Self.truseqReads()
        let d703 = (0...3).flatMap { k in (0..<2).map { "D703|k\(k)-\($0)" } }
        let d702 = (0...2).flatMap { k in (0..<2).map { "D702|k\(k)-\($0)" } }
        XCTAssertEqual(d703.count + d702.count, 14)
        for location in [BarcodeLocation.fivePrime, .bothEnds] {
            let outcome = try await run(
                BarcodeKitRegistry.truseqSingleA, reads, location: location, fivePrime: 8, errorRate: 0.15
            )
            report("(a)(b) \(location)", outcome, d703 + d702)
            for name in d703 { XCTAssertEqual(outcome.row(of: name), "D703", "(a) \(location) \(name)") }
            for name in d702 { XCTAssertEqual(outcome.row(of: name), "D702", "(b) \(location) \(name)") }
            XCTAssertEqual(outcome.wrong, [], "\(location)")
            XCTAssertEqual(outcome.placedCount, 216, "\(location)")
            XCTAssertEqual(outcome.unassignedCount, 0, "\(location)")
            XCTAssertEqual(outcome.ambiguous, 0, "\(location): the run checked its reads and no two rows tied")
            XCTAssertNil(outcome.line, "\(location): no line at a count of 0")
            for (name, _) in reads {
                XCTAssertEqual(outcome.sequence(of: name), afterIndex[name], "\(location) \(name) is trimmed after its index")
            }
        }
    }

    // MARK: - (c) Two rows of a Custom Definition fit a read equally

    /// Rows `TGGGCGAA` and `AGTGGGCG`, 3' End, 3' Distance 3, error 0, read = insert + `AGTGGGCGAA` (BIO-SINGLE-OFFSET item 2
    /// (c)). The first row fits it at the read end and the second 2 bases in, both with no error. At the base the second
    /// row's line `AGTGGGCGN{2}$` outscored the first's at 10 over 8 and the read landed in `AGTGGGCG`. No further key
    /// breaks a tie, so it goes to Unassigned whole and is counted (BIO-OFFSET-TIES items 1 and 3). The line names the 3'
    /// Distance and the end of the read, since the lines search only the 3' end.
    func testAReadThatTwoRowsFitEquallyAtTheThreePrimeEndGoesToUnassignedAndIsCounted() async throws {
        let kit = try customKit([("TGGGCGAA", "TGGGCGAA"), ("AGTGGGCG", "AGTGGGCG")])
        var bases = DemultiplexDualFormTests.Bases()
        let tied: Read = ("TGGGCGAA|c", bases.next(60) + "CCCCC" + "AGTGGGCGAA")
        // Five reads of each row with its barcode at the read end behind `CCCCC`, which only their own row fits.
        let fillers: [Read] = ["TGGGCGAA", "AGTGGGCG"].flatMap { row in
            (0..<5).map { index -> Read in ("\(row)|end-\(index)", bases.next(60) + "CCCCC" + row) }
        }
        let outcome = try await run(kit, [tied] + fillers, location: .threePrime, threePrime: 3, errorRate: 0)
        report("(c)", outcome, [tied.name])
        XCTAssertNotEqual(outcome.row(of: tied.name), "AGTGGGCG", "the line further in no longer takes the read")
        XCTAssertEqual(outcome.row(of: tied.name), "Unassigned")
        XCTAssertEqual(outcome.sequence(of: tied.name), tied.sequence, "Unassigned holds the read whole")
        XCTAssertEqual(outcome.unassignedCount, 1)
        XCTAssertEqual(outcome.ambiguous, 1)
        XCTAssertEqual(outcome.ends, .threePrime)
        XCTAssertEqual(
            outcome.line,
            "1 read went to Unassigned because it fits the barcodes of two or more samples equally well within the 3' "
                + "Distance, or the barcodes of another sample as well or better just past it. "
                + "Set the distance to the farthest your barcodes sit in from the end of the read, and if it is set that way "
                + "already, the barcodes alone cannot tell which sample each read belongs to."
        )
        for row in ["TGGGCGAA", "AGTGGGCG"] {
            XCTAssertEqual((outcome.placed[row] ?? []).map(\.name).sorted(), (0..<5).map { "\(row)|end-\($0)" }, row)
        }
        XCTAssertEqual(outcome.wrong, [])
    }

    /// The 5' mirror of (c): rows `TGGGCGAA` and `GGCGAAGT`, 5' Distance 3, error 0, read = `TGGGCGAAGT` + insert. The first
    /// row fits it at the read start and the second 2 bases in, both with no error, and the second's line `^N{2}GGCGAAGT`
    /// outscored the first's at the base. At 5' End and at Both Ends, which writes the 5' End lines, the read goes to
    /// Unassigned, and the line names the 5' Distance and the start of the read (FIX-OFFSET-SHIFT item 2).
    func testAReadThatTwoRowsFitEquallyAtTheFivePrimeEndGoesToUnassignedAtFivePrimeEndAndBothEnds() async throws {
        let kit = try customKit([("TGGGCGAA", "TGGGCGAA"), ("GGCGAAGT", "GGCGAAGT")])
        var bases = DemultiplexDualFormTests.Bases()
        let tied: Read = ("TGGGCGAA|c5", "TGGGCGAAGT" + "CCCCC" + bases.next(60))
        let fillers: [Read] = ["TGGGCGAA", "GGCGAAGT"].flatMap { row in
            (0..<5).map { index -> Read in ("\(row)|start-\(index)", row + "CCCCC" + bases.next(60)) }
        }
        for location in [BarcodeLocation.fivePrime, .bothEnds] {
            let outcome = try await run(kit, [tied] + fillers, location: location, fivePrime: 3, errorRate: 0)
            report("(c5) \(location)", outcome, [tied.name])
            XCTAssertNotEqual(outcome.row(of: tied.name), "GGCGAAGT", "\(location): the line further in no longer takes it")
            XCTAssertEqual(outcome.row(of: tied.name), "Unassigned", "\(location)")
            XCTAssertEqual(outcome.sequence(of: tied.name), tied.sequence, "\(location): Unassigned holds the read whole")
            XCTAssertEqual(outcome.unassignedCount, 1, "\(location)")
            XCTAssertEqual(outcome.ambiguous, 1, "\(location)")
            XCTAssertEqual(outcome.ends, .fivePrime, "\(location)")
            XCTAssertEqual(
                outcome.line,
                "1 read went to Unassigned because it fits the barcodes of two or more samples equally well within the 5' "
                    + "Distance, or the barcodes of another sample as well or better just past it. "
                    + "Set the distance to the farthest your barcodes sit in from the start of the read, and if it is set that "
                    + "way already, the barcodes alone cannot tell which sample each read belongs to.",
                "\(location)"
            )
            XCTAssertEqual(outcome.wrong, [], "\(location)")
            XCTAssertEqual(outcome.placedCount, 10, "\(location)")
        }
    }

    // MARK: - Green before and after the fix

    /// At error 0 the real flank completes no other barcode, so every TruSeq read, its index from 0 to 8 bases in and so
    /// exactly at the distance too, lands in its own row trimmed after its index, before and after the fix
    /// (BIO-SINGLE-OFFSET Q2, 216 of 216).
    func testTruSeqReadsUpToAndAtTheDistanceStayInTheirOwnRowsAtErrorZero() async throws {
        let (reads, afterIndex) = Self.truseqReads()
        let outcome = try await run(BarcodeKitRegistry.truseqSingleA, reads, location: .fivePrime, fivePrime: 8, errorRate: 0)
        report("e0", outcome, ["D703|k8-0", "D702|k8-0"])
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertEqual(outcome.placedCount, 216)
        XCTAssertEqual(outcome.unassignedCount, 0)
        for (name, _) in reads { XCTAssertEqual(outcome.sequence(of: name), afterIndex[name], name) }
    }

    /// The 96 well-spread 24-base ONT native barcodes as a Custom Definition with one sequence a row, at 5' Distance 3:
    /// `AAGGTTAA`'s last k bases, the barcode, `CAGCACCT` and an insert, two reads of each row at each k from 0 to 3. No
    /// read lands in another row, at error 0 or 0.15, before and after the fix (BIO-SINGLE-OFFSET Q2, 0 wrong of 768).
    func testTheONTNativeBarcodesAsACustomDefinitionStayInTheirOwnRows() async throws {
        let rows = BarcodeKitRegistry.ontNativeBarcoding96.barcodes.map { (name: $0.id, sequence: $0.i7Sequence) }
        XCTAssertEqual(rows.count, 96)
        XCTAssertTrue(rows.allSatisfy { $0.sequence.count == 24 })
        let kit = try customKit(rows)
        var bases = DemultiplexDualFormTests.Bases(state: 0x0A7)
        let reads: [Read] = rows.flatMap { row in
            (0...3).flatMap { k in
                (0..<2).map { index -> Read in
                    ("\(row.name)|k\(k)-\(index)", String("AAGGTTAA".suffix(k)) + row.sequence + "CAGCACCT" + bases.next(40))
                }
            }
        }
        for errorRate in [0.0, 0.15] {
            let outcome = try await run(kit, reads, location: .fivePrime, fivePrime: 3, errorRate: errorRate)
            report("ont e\(errorRate)", outcome, [])
            XCTAssertEqual(outcome.wrong, [], "e \(errorRate)")
            XCTAssertEqual(outcome.placedCount, 768, "e \(errorRate)")
            XCTAssertEqual(outcome.unassignedCount, 0, "e \(errorRate)")
        }
    }

    /// With the searched distance at 0 no line holds an N, so the run does not check its reads: the result counts no
    /// read that two rows fit, and every read lands and is trimmed as before. The distance of the other end is not
    /// searched, so 5' End with only a 3' Distance, and 3' End with only a 5' Distance, are such runs too
    /// (BIO-SINGLE-OFFSET item 1).
    func testARunWhoseSearchedDistanceIsZeroIsTheSameAsBefore() async throws {
        let (all, afterIndex) = Self.truseqReads()
        // The reads with the index at the read start land in their rows. The reads 1 base in are found by no line.
        let atStart = all.filter { $0.name.contains("|k0-") }
        let oneIn = all.filter { $0.name.contains("|k1-") }
        for (fivePrime, threePrime) in [(0, 0), (0, 3)] {
            let outcome = try await run(
                BarcodeKitRegistry.truseqSingleA, atStart + oneIn, location: .fivePrime, fivePrime: fivePrime,
                threePrime: threePrime, errorRate: 0
            )
            let label = "5' End at \(fivePrime)/\(threePrime)"
            XCTAssertNil(outcome.ambiguous, label)
            XCTAssertNil(outcome.ends, label)
            XCTAssertEqual(outcome.wrong, [], label)
            XCTAssertEqual(outcome.placedCount, 24, label)
            for (name, _) in atStart { XCTAssertEqual(outcome.sequence(of: name), afterIndex[name], "\(label) \(name)") }
            XCTAssertEqual(outcome.unassigned.map(\.name).sorted(), oneIn.map(\.name).sorted(), label)
            for read in oneIn { XCTAssertEqual(outcome.sequence(of: read.name), read.sequence, "\(label) \(read.name)") }
        }
        // 3' End with only a 5' Distance: the pair of (c) at the read end lands in the row the base's line ranks first.
        let kit = try customKit([("TGGGCGAA", "TGGGCGAA"), ("AGTGGGCG", "AGTGGGCG")])
        var bases = DemultiplexDualFormTests.Bases()
        let reads: [Read] = ["TGGGCGAA", "AGTGGGCG"].map { row in ("\(row)|end", bases.next(60) + "CCCCC" + row) }
        let outcome = try await run(kit, reads, location: .threePrime, fivePrime: 3, errorRate: 0)
        XCTAssertNil(outcome.ambiguous, "3' End at 3/0")
        XCTAssertNil(outcome.ends, "3' End at 3/0")
        XCTAssertEqual(outcome.wrong, [], "3' End at 3/0")
        XCTAssertEqual(outcome.placedCount, 2, "3' End at 3/0")
        XCTAssertEqual(outcome.sequence(of: "TGGGCGAA|end"), String(reads[0].sequence.dropLast(8)), "trimmed before the barcode")
    }
}
