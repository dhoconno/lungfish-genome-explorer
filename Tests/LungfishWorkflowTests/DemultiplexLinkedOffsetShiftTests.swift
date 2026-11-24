// DemultiplexLinkedOffsetShiftTests.swift - A read of a built-in Illumina dual kit stays only in the row that fits it at the fewest errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-LINKED-OFFSET-SHIFT (ruling BIO-LINKED-OFFSET items 1 to 4, BIO-OFFSET-TIES items 1 and 4, S1). At Both Ends
// with a 5' or 3' Distance above 0, the built-in TruSeq HT Dual Index and Nextera XT Index Kit v2 kits, and a definition
// whose `# kit:` line names one of them or IDT for Illumina UD Indexes, write a line for each pair and each two offsets,
// `^N{a}i7...rc(i5)N{b}$`, and the other strand `^N{a}i5...rc(i7)N{b}$`. Cutadapt ranks the lines that match a read by
// score and scores each N as a matched base, so a line of another row further in beat the right row's line at the read
// ends and moved the read into another sample with no word. A read now stays in a row only when no other row fits it at
// the same or fewer errors, and a read that two rows fit equally goes to Unassigned and is counted. Each test but the
// first runs Cutadapt. Every Illumina kit trims poly-G (`--nextseq-trim=20`), so Cutadapt and the check search each read
// with its final G's cut, and each test names the reads whose 3' index the trim cuts (LINKED-CONT).

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexLinkedOffsetShiftTests: XCTestCase {
    var project: URL!
    var dir: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexLinkedOffsetShiftTests-\(UUID().uuidString).lungfish", isDirectory: true)
        dir = project.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    typealias Read = DemultiplexDualFormTests.Read
    typealias Outcome = DemultiplexSingleOffsetShiftTests.Outcome

    /// The bases around the two indexes of a molecule: before i7, after i7, before rc(i5) and after rc(i5) on the strand
    /// that starts with i7 (BIO-LINKED-OFFSET Q2, the real flanks).
    struct Flanks {
        let beforeI7: String
        let afterI7: String
        let beforeI5: String
        let afterI5: String
    }

    static let truseq = Flanks(
        beforeI7: "CCAGTCAC", afterI7: "ATCTCGTATGCCGTCTTCTGCTTG",
        beforeI5: "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT", afterI5: "GTGTAGATCTCGGTGGTCGCCGTATCATT"
    )
    static let nextera = Flanks(
        beforeI7: "CTCCGAGCCCACGAGAC", afterI7: "ATCTCGTATGCCGTCTTCTGCTTG",
        beforeI5: "CTGTCTCTTATACACATCTGACGCTGCCGACGA", afterI5: "GTGTAGATCTCGGTGGTCGCCGTATCATT"
    )

    /// Reads of the rows `rows` of `kit`, each molecule with its indexes `k` bases in from both read ends: the last k bases
    /// before i7, i7, the bases after it, a 60-base insert, the bases before rc(i5), rc(i5) and the first k bases after it.
    /// `strands` holds F for the molecule as written, R for its reverse complement, or both. A read's name is
    /// `<row>|k<k>|<strand>`, and `trimmed` holds the bases between its two indexes, which its own row's line keeps.
    static func reads(
        _ kit: BarcodeKitDefinition, _ flanks: Flanks, _ rows: [(id: String, k: Int, strands: String)]
    ) throws -> (reads: [Read], trimmed: [String: String]) {
        var bases = DemultiplexDualFormTests.Bases()
        var reads: [Read] = []
        var trimmed: [String: String] = [:]
        for (id, k, strands) in rows {
            let row = try XCTUnwrap(kit.barcodes.first { $0.id == id }, id)
            let i5 = try XCTUnwrap(row.i5Sequence, id)
            let middle = flanks.afterI7 + bases.next(60) + flanks.beforeI5
            let forward = String(flanks.beforeI7.suffix(k)) + row.i7Sequence + middle
                + PlatformAdapters.reverseComplement(i5) + String(flanks.afterI5.prefix(k))
            for strand in strands {
                let name = "\(id)|k\(k)|\(strand)"
                let reverse = strand == "R"
                reads.append((name, reverse ? PlatformAdapters.reverseComplement(forward) : forward))
                trimmed[name] = reverse ? PlatformAdapters.reverseComplement(middle) : middle
            }
        }
        return (reads, trimmed)
    }

    func writeFASTQ(_ reads: [Read]) throws -> URL {
        let url = dir.appendingPathComponent("reads-\(UUID().uuidString).fastq")
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func records(_ url: URL) async throws -> [Read] {
        var reads: [Read] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            reads.append((record.identifier, record.sequence))
        }
        return reads
    }

    /// A Cutadapt run of `kit` at Both Ends with both distances at `distance`, as the dialog and the command run it.
    func run(_ kit: BarcodeKitDefinition, _ reads: [Read], distance: Int, errorRate: Double) async throws -> Outcome {
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: try writeFASTQ(reads), barcodeKit: kit, outputDirectory: output, barcodeLocation: .bothEnds,
            errorRate: errorRate, maxDistanceFrom5Prime: distance, maxDistanceFrom3Prime: distance,
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
        print("LINKEDOFFSET \(label): \(rows); wrong \(outcome.wrong.count) \(outcome.wrong.prefix(16)); "
              + "unassigned \(outcome.unassignedCount); ambiguousReads \(outcome.ambiguous.map(String.init) ?? "nil")")
    }

    /// The row a read's name starts with.
    func own(_ name: String) -> String { String(name.split(separator: "|")[0]) }

    /// The bases the run's NextSeq trim cuts from the 3' end of `sequence`. Every Illumina kit trims poly-G
    /// (`--nextseq-trim=20`), and Cutadapt cuts each read's final G's (every quality here is `I`) before it searches the
    /// lines, so Cutadapt and the check both search the read as cut, and Unassigned holds it as cut.
    static func cut(_ sequence: String, _ kit: BarcodeKitDefinition) -> Int {
        guard let cutoff = kit.platform.defaultPolyGTrimQuality else { return 0 }
        let bases = Array(sequence.utf8)
        let qualities = [UInt8](repeating: UInt8(ascii: "I"), count: bases.count)
        return bases.count - DemultiplexingPipeline.nextseqTrimIndex(bases, qualities, cutoff: cutoff)
    }

    /// The bases of a made read's 3' index the trim cuts: the cut first takes the `k` bases past the index that the
    /// read's name `<row>|k<k>|<strand>` gives.
    static func indexBasesCut(_ read: Read, _ kit: BarcodeKitDefinition) -> Int {
        let part = read.name.split(separator: "|").dropFirst().first ?? ""
        let k = part.hasPrefix("k") ? Int(part.dropFirst()) ?? 0 : 0
        return max(0, cut(read.sequence, kit) - k)
    }

    /// A Custom Definition whose `# kit:` line names `kitLine`, read from a file in `dir` as the dialog and the command read it.
    static func definition(_ kitLine: String, _ rows: [String], in dir: URL) throws -> BarcodeKitDefinition {
        let csv = dir.appendingPathComponent("\(kitLine).csv")
        try (["# kit: \(kitLine)", "id,sequence,secondary_sequence"] + rows).joined(separator: "\n").appending("\n")
            .write(to: csv, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: csv, name: "plate-\(kitLine)")
        XCTAssertEqual(kit.sourceKitID, kitLine)
        XCTAssertEqual(kit.pairingMode, .fixedDual)
        return kit
    }

    /// A `# kit: truseq-ht-dual` definition of the rows `ids` of the built-in TruSeq HT kit, with the kit's own sequences
    /// (BIO-DEMUX-CAP item 5). Two rows at 8/8 are 2 x 81 x 2 = 324 lines, where the 96-row kit's 15,552 are refused.
    static func truseqDefinition(_ ids: [String], in dir: URL) throws -> BarcodeKitDefinition {
        let rows = try ids.map { id -> String in
            let row = try XCTUnwrap(BarcodeKitRegistry.truseqHTDual.barcodes.first { $0.id == id }, id)
            return "\(id),\(row.i7Sequence),\(try XCTUnwrap(row.i5Sequence, id))"
        }
        return try definition("truseq-ht-dual", rows, in: dir)
    }

    /// Asserts that `kit` at Both Ends and `distance` for both distances takes the built-in dual route, not the observed one.
    func assertBuiltInRoute(_ kit: BarcodeKitDefinition, distance: Int) {
        let config = DemultiplexConfig(
            inputURL: dir.appendingPathComponent("reads.fastq"), barcodeKit: kit, outputDirectory: dir,
            barcodeLocation: .bothEnds, maxDistanceFrom5Prime: distance, maxDistanceFrom3Prime: distance, engine: .cutadapt
        )
        let pipeline = DemultiplexingPipeline()
        XCTAssertTrue(pipeline.searchesBuiltInDualPairsAtAnOffset(config), "\(kit.id) takes the built-in dual route")
        XCTAssertFalse(pipeline.usesObservedCustomBarcodePairs(config), "\(kit.id) is not the observed route")
    }

    // MARK: - The route the check runs on

    /// The check runs on the lines `writeLinkedAdapterFASTA` writes through the built-in dual route: the built-in TruSeq HT
    /// and Nextera XT v2 kits, and a definition whose `# kit:` line names one of them or IDT for Illumina UD Indexes, at
    /// Both Ends with no sample sheet and a 5' or 3' Distance above 0 (BIO-LINKED-OFFSET items 1 and 2). It does not run
    /// at 0/0, with a sample sheet, or at one read end, which the preflight refuses for a dual kit.
    func testTheCheckRunsOnTheBuiltInDualRouteOnlyWithADistance() throws {
        let pipeline = DemultiplexingPipeline()
        func checks(
            _ kit: BarcodeKitDefinition, _ fivePrime: Int, _ threePrime: Int, location: BarcodeLocation = .bothEnds,
            sheet: Bool = false
        ) -> Bool {
            let assignments = sheet ? [FASTQSampleBarcodeAssignment(sampleID: "S1", forwardBarcodeID: kit.barcodes[0].id)] : []
            return pipeline.checksPlacedReadsByFewestErrors(DemultiplexConfig(
                inputURL: dir.appendingPathComponent("reads.fastq"), barcodeKit: kit, outputDirectory: dir,
                barcodeLocation: location, maxDistanceFrom5Prime: fivePrime, maxDistanceFrom3Prime: threePrime,
                engine: .cutadapt, sampleAssignments: assignments
            ))
        }
        let kits = try [
            BarcodeKitRegistry.truseqHTDual, BarcodeKitRegistry.nexteraXTv2,
            Self.definition("truseq-ht-dual", ["D702-D508,TCCGGAGA,GTACTGAC", "D706-D508,GAATTCGT,GTACTGAC"], in: dir),
            Self.definition("nextera-xt-v2", ["N711-S502,AAGAGGCA,CTCTCTAT", "N703-S502,AGGCAGAA,CTCTCTAT"], in: dir),
            Self.definition("idt-ud-indexes", ["W01,ACGTTGCAAC,TTGGCCAAGG", "W02,TGCAACGTTG,CCAAGGTTGG"], in: dir),
        ]
        for kit in kits {
            XCTAssertTrue(checks(kit, 3, 3), "\(kit.id) at 3/3")
            XCTAssertTrue(checks(kit, 8, 0), "\(kit.id) with only a 5' Distance")
            XCTAssertTrue(checks(kit, 0, 1), "\(kit.id) with only a 3' Distance")
            XCTAssertFalse(checks(kit, 0, 0), "\(kit.id) at 0/0")
            XCTAssertFalse(checks(kit, 3, 3, sheet: true), "\(kit.id) with a sample sheet")
            XCTAssertFalse(checks(kit, 3, 3, location: .fivePrime), "\(kit.id) at 5' End")
            XCTAssertFalse(checks(kit, 3, 3, location: .threePrime), "\(kit.id) at 3' End")
        }
    }

    // MARK: - (a) and (b) D702-D508 of the built-in TruSeq HT kit at 8/8

    /// A `# kit: truseq-ht-dual` definition of D702-D508 and D706-D508 at Both Ends, 8/8, the default error rate 0.15
    /// (BIO-LINKED-OFFSET item 2 (a) and (b)), 324 lines on the built-in route. It ran on the built-in kit until the 15,552
    /// lines of that kit at 8/8 were refused (BIO-DEMUX-CAP item 5), and it expects what it expected there. D706 `GAATTCGT`
    /// fits a D702 read with one indel 6 bases further in than D702 `TCCGGAGA`, so for a molecule whose indexes sit 0 to 2
    /// bases in, the line of D706-D508 with its 6 more N's outscored D702-D508's, and the read and its reverse complement
    /// landed in D706-D508 at the base. D702-D508 fits them with no error, so they now land in D702-D508, trimmed between the
    /// two indexes as its own line trims them.
    func testTruSeqHTDefinitionReadsOfD702ThatD706FitsFurtherInLandInTheirOwnRow() async throws {
        let kit = try Self.truseqDefinition(["D702-D508", "D706-D508"], in: dir)
        assertBuiltInRoute(kit, distance: 8)
        let rows = (0...2).map { (id: "D702-D508", k: $0, strands: "FR") }
        let (reads, trimmed) = try Self.reads(kit, Self.truseq, rows)
        XCTAssertEqual(reads.count, 6)
        let outcome = try await run(kit, reads, distance: 8, errorRate: 0.15)
        report("(a)(b)", outcome, reads.map(\.name))
        for (name, _) in reads {
            XCTAssertNotEqual(outcome.row(of: name), "D706-D508", "\(name): the line further in no longer takes it")
            XCTAssertEqual(outcome.row(of: name), "D702-D508", name)
            XCTAssertEqual(outcome.sequence(of: name), trimmed[name], "\(name) is trimmed between its indexes")
        }
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertEqual(outcome.placedCount, 6)
        XCTAssertEqual(outcome.unassignedCount, 0)
        XCTAssertEqual(outcome.ambiguous, 0, "the run checked its reads and no two rows tied")
        XCTAssertNil(outcome.line, "no line at a count of 0")
    }

    // MARK: - (c) The D703 rows at 8/8

    /// D701 `ATTACTCG` fits a D703 `CGCTCATT` read with one indel 5 bases further in, so at 8/8 and error 0.15 every read of
    /// a D703 row whose indexes sit 0 to 3 bases in landed in D701 at the base (BIO-LINKED-OFFSET item 2 (c), all 8 D703
    /// rows at 3 bases in; BIO-SINGLE-OFFSET Q2). They now leave D701. D703-D501 and D703-D508 fit their reads with no
    /// error on the strand as written, and on the other strand at 2 and 3 bases in, so those 12 land in their own rows. On
    /// the other strand at 0 and 1 bases in the read ends in rc(D703) `AATGAGCG`, then `G` at 1 base in, and the NextSeq
    /// trim cuts those final G's before the search. D703 then fits the cut read with one error, the G it lost, and D701
    /// fits it with one indel 4 bases in, so the two rows tie and those 4 reads go to Unassigned as cut and are counted.
    ///
    /// The case runs on a `# kit: truseq-ht-dual` definition of D701-D501, D701-D508, D703-D501 and D703-D508, 648 lines at
    /// 8/8, since the built-in kit's 15,552 lines are refused (BIO-DEMUX-CAP item 5), and it expects what it expected there.
    func testTruSeqHTDefinitionReadsOfD703ThatD701FitsFurtherInLandInTheirOwnRows() async throws {
        let kit = try Self.truseqDefinition(["D701-D501", "D701-D508", "D703-D501", "D703-D508"], in: dir)
        assertBuiltInRoute(kit, distance: 8)
        let rows = ["D703-D501", "D703-D508"].flatMap { id in (0...3).map { (id: id, k: $0, strands: "FR") } }
        let (reads, trimmed) = try Self.reads(kit, Self.truseq, rows)
        XCTAssertEqual(reads.count, 16)
        let tied = reads.filter { Self.indexBasesCut($0, kit) > 0 }.map(\.name)
        XCTAssertEqual(tied, ["D703-D501|k0|R", "D703-D501|k1|R", "D703-D508|k0|R", "D703-D508|k1|R"])
        let outcome = try await run(kit, reads, distance: 8, errorRate: 0.15)
        report("(c)", outcome, reads.map(\.name))
        for (name, sequence) in reads {
            XCTAssertFalse(outcome.row(of: name).hasPrefix("D701-"), "\(name) is in \(outcome.row(of: name)), the row further in")
            if tied.contains(name) {
                XCTAssertEqual(outcome.row(of: name), "Unassigned", "\(name) ties D703 and D701 at one error")
                XCTAssertEqual(outcome.sequence(of: name), String(sequence.dropLast(Self.cut(sequence, kit))), "\(name) as cut")
            } else {
                XCTAssertEqual(outcome.row(of: name), own(name), name)
                XCTAssertEqual(outcome.sequence(of: name), trimmed[name], "\(name) is trimmed between its indexes")
            }
        }
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertEqual(outcome.placedCount, 12)
        XCTAssertEqual(outcome.unassignedCount, 4)
        XCTAssertEqual(outcome.ambiguous, 4)
    }

    // MARK: - (d) A Nextera read that two rows fit equally

    /// The 57 bases of (d) between `GAA` and rc(S502), fixed so that no third row's lines fit the read within 7 bases of
    /// either end, the distances and the 4 bases past them that the check also fits.
    static let nexteraInsert = "GCAGGTGGCGTGAAGAGTACTCGGCAAACATGACGGGGACTAGACGACTGGAAGCAG"

    /// The built-in Nextera XT Index Kit v2 at Both Ends, 3/3, error 0 (BIO-LINKED-OFFSET item 2 (d), BIO-OFFSET-TIES item
    /// 4). The read is N711 `AAGAGGCA`, `GAA`, 57 bases, `ATAGAGAG`, rc(S502), and `GT`, the first 2 bases of the real flank
    /// past rc(S502). A read that ended in rc(S502) would end in G, which the NextSeq trim cuts before the search, so at
    /// error 0 no line would fit it and, with every read so cut, the chance floor would refuse the run. N703 `AGGCAGAA` is
    /// N711 moved 3 bases in, so the line `^N{3}AGGCAGAA...ATAGAGAGN{2}$` scored 11 + 10 over N711-S502's 8 + 10 and put
    /// the read in N703-S502 at the base. Both rows fit it with no error, and no further key breaks a tie, so it goes to
    /// Unassigned whole and is counted in the words of both distances. Two reads of each row that only their own row fits
    /// stay in it, so each row beats the floor.
    func testANexteraReadThatTwoRowsFitEquallyGoesToUnassignedAndIsCounted() async throws {
        XCTAssertEqual(Self.nexteraInsert.count, 57)
        let tied: Read = ("N711-S502|tied", "AAGAGGCA" + "GAA" + Self.nexteraInsert + "ATAGAGAG" + "GT")
        let fillers: [Read] = [("N711-S502", "AAGAGGCA"), ("N703-S502", "AGGCAGAA")].flatMap { row, i7 in
            (0..<2).map { index -> Read in ("\(row)|fill-\(index)", i7 + "CCC" + Self.nexteraInsert + "ATAGAGAG" + "GT") }
        }
        for (name, sequence) in [tied] + fillers {
            XCTAssertEqual(Self.cut(sequence, BarcodeKitRegistry.nexteraXTv2), 0, "the trim cuts no base of \(name)")
        }
        let outcome = try await run(BarcodeKitRegistry.nexteraXTv2, [tied] + fillers, distance: 3, errorRate: 0)
        report("(d)", outcome, [tied.name] + fillers.map(\.name))
        XCTAssertNotEqual(outcome.row(of: tied.name), "N703-S502", "the line further in no longer takes the read")
        XCTAssertEqual(outcome.row(of: tied.name), "Unassigned")
        XCTAssertEqual(outcome.sequence(of: tied.name), tied.sequence, "Unassigned holds the read whole")
        XCTAssertEqual(outcome.unassignedCount, 1)
        XCTAssertEqual(outcome.ambiguous, 1)
        XCTAssertEqual(outcome.ends, .both)
        XCTAssertEqual(
            outcome.line,
            "1 read went to Unassigned because it fits the barcodes of two or more samples equally well within the 5' and "
                + "3' Distance, or the barcodes of another sample as well or better just past it. "
                + "Set each distance to the farthest your barcodes sit in from the read ends, and if each is set that way "
                + "already, the barcodes alone cannot tell which sample each read belongs to."
        )
        for row in ["N711-S502", "N703-S502"] {
            XCTAssertEqual((outcome.placed[row] ?? []).map(\.name).sorted(), ["\(row)|fill-0", "\(row)|fill-1"], row)
        }
        XCTAssertEqual(outcome.wrong, [])
    }

    // MARK: - (e) Green before and after the fix

    /// At 0/0 no line holds an N and the run does not check its reads, so both kits place and trim reads as before: a
    /// molecule of each row with its indexes at the read ends, on both strands (BIO-LINKED-OFFSET item 2 (e)). The NextSeq
    /// trim cuts the final G's of a read whose 3' index ends in G before the search, and each G it cuts is one error of
    /// that index. A read that loses more than floor(e x 8) goes to Unassigned as cut, before this lane as after it: at
    /// error 0.15 the 12 TruSeq HT reads `D7xx-D503|k0|F`, which end in rc(D503) `AGGATAGG`, and at error 0 the 48 TruSeq
    /// HT and 52 Nextera reads that end in G. Every other read lands in its own row, trimmed between its indexes.
    func testBothKitsAtNoDistanceAreTheSameAsBefore() async throws {
        let lost = ["truseq-ht-dual 0.0": 48, "truseq-ht-dual 0.15": 12, "nextera-xt-v2 0.0": 52, "nextera-xt-v2 0.15": 0]
        for (kit, flanks) in [(BarcodeKitRegistry.truseqHTDual, Self.truseq), (BarcodeKitRegistry.nexteraXTv2, Self.nextera)] {
            let (reads, trimmed) = try Self.reads(kit, flanks, kit.barcodes.map { (id: $0.id, k: 0, strands: "FR") })
            for errorRate in [0.0, 0.15] {
                let label = "\(kit.id) \(errorRate)"
                // Each index is 8 bases, so each fits with at most floor(e x 8) errors.
                let budget = Int((errorRate * 8).rounded(.down))
                let cutPast = Set(reads.filter { Self.indexBasesCut($0, kit) > budget }.map(\.name))
                XCTAssertEqual(cutPast.count, lost[label], label)
                let outcome = try await run(kit, reads, distance: 0, errorRate: errorRate)
                report("(e) 0/0 \(label)", outcome, [])
                XCTAssertNil(outcome.ambiguous, label)
                XCTAssertNil(outcome.ends, label)
                XCTAssertEqual(outcome.wrong, [], label)
                XCTAssertEqual(outcome.placedCount, reads.count - cutPast.count, label)
                XCTAssertEqual(outcome.unassignedCount, cutPast.count, label)
                for (name, sequence) in reads {
                    if cutPast.contains(name) {
                        XCTAssertEqual(outcome.row(of: name), "Unassigned", "\(label) \(name)")
                        XCTAssertEqual(outcome.sequence(of: name), String(sequence.dropLast(Self.cut(sequence, kit))), "\(label) \(name)")
                    } else {
                        XCTAssertEqual(outcome.row(of: name), own(name), "\(label) \(name)")
                        XCTAssertEqual(outcome.sequence(of: name), trimmed[name], "\(label) \(name)")
                    }
                }
            }
        }
    }

    /// Reads whose indexes sit exactly at the distance, 4 bases in at 4/4 and error 0.15, land in their own rows before and
    /// after: each i7 with D508 on both strands, and D702 and D703 with each other i5 (BIO-LINKED-OFFSET item 2 (e), 576
    /// of 576, moved from 8/8 to 4/4 by BIO-DEMUX-CAP item 5 since the built-in kit's 15,552 lines at 8/8 are refused). The
    /// lines of D706 and D701 fit the D702 and D703 reads 10 and 9 bases in, past the distance and the 4 bases the check
    /// also fits. The trim cuts no index base of any read.
    func testTruSeqHTReadsWithTheirIndexesAtTheDistanceStayInTheirOwnRows() async throws {
        let kit = BarcodeKitRegistry.truseqHTDual
        let withD508 = BarcodeKitRegistry.truseqSingleA.barcodes.map { (id: "\($0.id)-D508", k: 4, strands: "FR") }
        let others = ["D702", "D703"].flatMap { i7 in
            BarcodeKitRegistry.truseqSingleB.barcodes.filter { $0.id != "D508" }.map { (id: "\(i7)-\($0.id)", k: 4, strands: "F") }
        }
        let (reads, trimmed) = try Self.reads(kit, Self.truseq, withD508 + others)
        XCTAssertEqual(reads.count, 38)
        XCTAssertEqual(reads.filter { Self.indexBasesCut($0, kit) > 0 }.map(\.name), [])
        let outcome = try await run(kit, reads, distance: 4, errorRate: 0.15)
        report("(e) k4", outcome, [])
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertEqual(outcome.placedCount, 38)
        XCTAssertEqual(outcome.unassignedCount, 0)
        XCTAssertEqual(outcome.ambiguous ?? 0, 0)
        for (name, _) in reads { XCTAssertEqual(outcome.sequence(of: name), trimmed[name], name) }
    }

    /// The 96 rows of TruSeq HT at 3/3, a molecule of each with its indexes 0 to 3 bases in, four rows on one strand and the
    /// next four on the other, land in their own rows trimmed between their indexes at error 0 and 0.15, before and after
    /// (BIO-LINKED-OFFSET item 2 (e), 1,536 of 1,536 each). A line further in needs 5 or 6 bases more, past the distance.
    /// rc(i7) of D703, D707 and D709 ends in G, and the real flank past it starts with G, so on the other strand their
    /// reads at 0 and 1 bases in end in G's that the NextSeq trim cuts into the index before the search. At error 0 no line
    /// fits such a read, and with one read a row the chance floor refuses the run. So the six rows with D505 and D506 that
    /// the pattern puts on that strand are made on the strand as written, and the trim cuts no index base of any read.
    func testTruSeqHTReadsAtThreeBasesInStayInTheirOwnRowsAtBothErrorRates() async throws {
        let kit = BarcodeKitRegistry.truseqHTDual
        let pattern = kit.barcodes.enumerated().map { index, row in
            (id: row.id, k: index % 4, strands: (index / 4) % 2 == 0 ? "F" : "R")
        }
        let cutInto = try Self.reads(kit, Self.truseq, pattern).reads.filter { Self.indexBasesCut($0, kit) > 0 }.map { own($0.name) }
        XCTAssertEqual(cutInto, ["D703-D505", "D703-D506", "D707-D505", "D707-D506", "D709-D505", "D709-D506"])
        let rows = pattern.map { row in cutInto.contains(row.id) ? (id: row.id, k: row.k, strands: "F") : row }
        let (reads, trimmed) = try Self.reads(kit, Self.truseq, rows)
        XCTAssertEqual(reads.count, 96)
        XCTAssertEqual(reads.filter { Self.indexBasesCut($0, kit) > 0 }.map(\.name), [])
        for errorRate in [0.0, 0.15] {
            let outcome = try await run(BarcodeKitRegistry.truseqHTDual, reads, distance: 3, errorRate: errorRate)
            report("(e) 3/3 e\(errorRate)", outcome, [])
            XCTAssertEqual(outcome.wrong, [], "e \(errorRate)")
            XCTAssertEqual(outcome.placedCount, 96, "e \(errorRate)")
            XCTAssertEqual(outcome.unassignedCount, 0, "e \(errorRate)")
            XCTAssertEqual(outcome.ambiguous ?? 0, 0, "e \(errorRate)")
            for (name, _) in reads { XCTAssertEqual(outcome.sequence(of: name), trimmed[name], "e \(errorRate) \(name)") }
        }
    }
}
