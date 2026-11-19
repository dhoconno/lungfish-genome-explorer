// DemultiplexSharedNameGzipTests.swift - A run whose adapter file names a row on two lines keeps every read of each output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane DEMUX-SHARED-NAME-GZIP (ruling BIO-SHARED-NAME-GZIP items 1 and 2, S1). Cutadapt 5.2 opens a writer for each line
// of the adapter file and keeps the last writer of each name. Each other writer of a name ends an empty gzip stream, 20
// bytes, at the start of the name's gzip output when Cutadapt closes it, so an output that has passed Cutadapt's write
// buffer, about 202 KB of gzip, reads as an empty member and bytes that are no gzip stream (FIX-MEM-GZIP, F2). A built-in
// dual kit at Both Ends with both distances 0, the command's defaults, writes each row on two lines, its forward strand
// and its other strand, and a sample sheet of a dual kit writes each sample on two lines. Such a run lost every read of
// each row past the buffer, exited 0 and counted only the reads it kept. Each test runs Cutadapt.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexSharedNameGzipTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexSharedNameGzipTests-\(UUID().uuidString).lungfish", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    }

    typealias Read = DemultiplexDualFormTests.Read
    typealias Row = (id: String, first: String, second: String)

    /// The smallest gzip output the ruling saw break, in bytes (BIO-SHARED-NAME-GZIP Q2). Each output of (a) and (b) is
    /// bigger.
    static let brokenGzipBytes = 202_811

    static func rc(_ sequence: String) -> String { PlatformAdapters.reverseComplement(sequence) }

    /// `perRow` reads of each row: the row's first barcode, `insert` bases and the reverse complement of its second, the
    /// strand `writeLinkedAdapterFASTA` writes first, and every other read the reverse complement of that whole read, the
    /// other strand. A read's name is `<row>|<n>|<F or R>`.
    static func pairReads(_ rows: [Row], perRow: Int, insert: Int = 120) -> [Read] {
        var bases = DemultiplexDualFormTests.Bases()
        var reads: [Read] = []
        reads.reserveCapacity(rows.count * perRow)
        for index in 0..<perRow {
            for row in rows {
                let forward = row.first + bases.next(insert) + rc(row.second)
                let other = index % 2 == 1
                reads.append(("\(row.id)|\(index)|\(other ? "R" : "F")", other ? rc(forward) : forward))
            }
        }
        return reads
    }

    func writeFASTQ(_ reads: [Read], _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var text = ""
        text.reserveCapacity(reads.count * 300)
        for read in reads {
            text += "@\(read.name)\n\(read.sequence)\n+\n\(String(repeating: "I", count: read.sequence.count))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Custom Definition of `rows`, with the `# kit:` line `kitLine` when it is given.
    func definition(_ rows: [String], name: String, kitLine: String? = nil) throws -> BarcodeKitDefinition {
        let url = dir.appendingPathComponent("\(name).csv")
        let header = (kitLine.map { ["# kit: \($0)"] } ?? []) + ["id,sequence,secondary_sequence"]
        try (header + rows).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return try BarcodeKitRegistry.loadCustomKit(from: url, name: name)
    }

    /// The file name Cutadapt's `-o` gives in the command the run records, `{name}.fastq` or `{name}.fastq.gz`.
    static func outputPattern(_ result: DemultiplexResult) -> String? {
        guard let argv = result.nativeCommand, let index = argv.firstIndex(of: "-o"), index + 1 < argv.count else { return nil }
        return URL(fileURLWithPath: argv[index + 1]).lastPathComponent
    }

    struct Outcome {
        var placed: [String: Int] = [:]
        /// The reads of each row, by the row their name names, in any row's file.
        var kept: [String: Int] = [:]
        var wrong: [String] = []
        var manifestDisagrees: [String] = []
        var smallFiles: [String] = []
        var unassigned = 0
        var inputReadCount = 0
        var pattern: String?
    }

    /// Runs `config` and reads every sample's file back.
    func run(_ config: DemultiplexConfig) async throws -> Outcome {
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        var outcome = Outcome()
        for barcode in result.manifest.barcodes {
            let bundle = config.outputDirectory.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), barcode.barcodeID)
            let bytes = try XCTUnwrap(try fastq.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            if bytes <= Self.brokenGzipBytes { outcome.smallFiles.append("\(barcode.barcodeID) \(bytes) B") }
            var count = 0
            for try await record in FASTQReader(validateSequence: false).records(from: fastq) {
                count += 1
                outcome.kept[String(record.identifier.prefix { $0 != "|" }), default: 0] += 1
                if !record.identifier.hasPrefix(barcode.barcodeID + "|") {
                    outcome.wrong.append("\(record.identifier) in \(barcode.barcodeID)")
                }
            }
            outcome.placed[barcode.barcodeID] = count
            if barcode.readCount != count {
                outcome.manifestDisagrees.append("\(barcode.barcodeID): manifest \(barcode.readCount), file \(count)")
            }
        }
        outcome.unassigned = result.manifest.unassigned.readCount
        outcome.inputReadCount = result.manifest.inputReadCount
        outcome.pattern = Self.outputPattern(result)
        print("SHAREDNAME placed \(outcome.placed.sorted { $0.key < $1.key }); unassigned \(outcome.unassigned); "
              + "input \(outcome.inputReadCount); -o \(outcome.pattern ?? "nil"); wrong \(outcome.wrong.prefix(4)); "
              + "manifest \(outcome.manifestDisagrees.prefix(4)); small \(outcome.smallFiles.prefix(4))")
        return outcome
    }

    func assertKeepsEveryRead(_ outcome: Outcome, rows: [String], perRow: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.placed, Dictionary(uniqueKeysWithValues: rows.map { ($0, perRow) }),
                       "every row holds its reads", file: file, line: line)
        XCTAssertEqual(outcome.wrong, [], file: file, line: line)
        XCTAssertEqual(outcome.manifestDisagrees, [], file: file, line: line)
        XCTAssertEqual(outcome.smallFiles, [], "each row's file is past the size where Cutadapt's gzip outputs broke",
                       file: file, line: line)
        XCTAssertEqual(outcome.unassigned, 0, file: file, line: line)
        XCTAssertEqual(outcome.placed.values.reduce(0, +) + outcome.unassigned, rows.count * perRow,
                       "the counts add up to the input", file: file, line: line)
        XCTAssertEqual(outcome.inputReadCount, rows.count * perRow, "the input count is the input's", file: file, line: line)
        XCTAssertEqual(outcome.pattern, "{name}.fastq", "Cutadapt writes plain outputs, gzipped after it ends",
                       file: file, line: line)
    }

    // MARK: - (a) A built-in dual kit at Both Ends 0/0

    /// The twelve i7 barcodes of Nextera XT Index Kit v2, each with one i5, so no two rows share a barcode.
    static let nexteraRowIDs = [
        "N701-S502", "N702-S503", "N703-S504", "N704-S505", "N705-S506", "N706-S507",
        "N707-S508", "N708-S502", "N709-S503", "N710-S504", "N711-S505", "N712-S506",
    ]

    func rows(of kit: BarcodeKitDefinition, _ ids: [String]) throws -> [Row] {
        try ids.map { id in
            let barcode = try XCTUnwrap(kit.barcodes.first { $0.id == id }, id)
            return (id, barcode.i7Sequence, try XCTUnwrap(barcode.i5Sequence, id))
        }
    }

    /// Ruling item 2 (a): the built-in Nextera XT v2 kit at Both Ends with both distances 0, the command's defaults, on
    /// one FASTQ of 84,000 reads over 12 rows, half on the other strand. Each row's output holds 7,000 reads, past the
    /// buffer. At the base Cutadapt wrote `{name}.fastq.gz`, every row's file broke, and the run counted none of them.
    func testANexteraRunAtBothEndsWithNoDistanceKeepsEveryReadOfTwelveRows() async throws {
        let kit = BarcodeKitRegistry.nexteraXTv2
        let reads = Self.pairReads(try rows(of: kit, Self.nexteraRowIDs), perRow: 7_000)
        let config = DemultiplexConfig(
            inputURL: try writeFASTQ(reads, "nextera.fastq"), barcodeKit: kit,
            outputDirectory: dir.appendingPathComponent("demux", isDirectory: true), barcodeLocation: .bothEnds,
            errorRate: 0.15, maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, trimBarcodes: true, threads: 4,
            engine: .cutadapt
        )
        assertKeepsEveryRead(try await run(config), rows: Self.nexteraRowIDs, perRow: 7_000)
    }

    // MARK: - (b) A dual kit with a sample sheet

    /// Ruling item 2 (b): Nextera XT v2 with a sample sheet of four samples, each a pair whose two barcodes differ, so
    /// each sample is written on two lines, `fwd...rc(rev)` and `rev...rc(fwd)`. A sheet of a dual kit reaches Cutadapt
    /// only when the run is not asymmetric, which the Swift exact search takes. Its lines are not anchored, which the
    /// chance check cannot judge, so the run keeps unchecked samples, as Keep Unchecked Samples does. 7,000 reads a
    /// sample, half on the other strand.
    func testADualKitWithASampleSheetKeepsEveryReadOfFourSamples() async throws {
        let kit = BarcodeKitRegistry.nexteraXTv2
        let pairs = try rows(of: kit, ["N701-S502", "N702-S503", "N703-S504", "N704-S505"])
        let samples = pairs.enumerated().map { (id: "S\($0.offset + 1)", first: $0.element.first, second: $0.element.second) }
        let reads = Self.pairReads(samples, perRow: 7_000)
        let config = DemultiplexConfig(
            inputURL: try writeFASTQ(reads, "sheet.fastq"), barcodeKit: kit,
            outputDirectory: dir.appendingPathComponent("demux", isDirectory: true), barcodeLocation: .bothEnds,
            symmetryMode: .symmetric, errorRate: 0.15, trimBarcodes: true, threads: 4, engine: .cutadapt,
            sampleAssignments: samples.map {
                FASTQSampleBarcodeAssignment(sampleID: $0.id, forwardSequence: $0.first, reverseSequence: $0.second)
            },
            keepsUncheckedSamples: true
        )
        let outcome = try await run(config)
        // Unanchored lines can put a read in another sample by chance, which is why the chance check asks for Keep
        // Unchecked Samples, so this test pins that no sample loses a read: each read is in some sample's file.
        XCTAssertEqual(outcome.kept, Dictionary(uniqueKeysWithValues: samples.map { ($0.id, 7_000) }), "no sample loses a read")
        XCTAssertEqual(outcome.manifestDisagrees, [])
        XCTAssertEqual(outcome.smallFiles, [], "each sample's file is past the size where Cutadapt's gzip outputs broke")
        XCTAssertEqual(outcome.unassigned, 0)
        XCTAssertEqual(outcome.placed.values.reduce(0, +) + outcome.unassigned, reads.count, "the counts add up to the input")
        XCTAssertEqual(outcome.inputReadCount, reads.count, "the input count is the input's")
        XCTAssertEqual(outcome.pattern, "{name}.fastq", "Cutadapt writes plain outputs, gzipped after it ends")
    }

    // MARK: - (c) The routes

    /// Ruling item 2 (c): each route writes plain temporaries when its adapter file names a row on two or more lines, and
    /// gzip ones when every name is on one line, which keeps those routes as they were. Read from Cutadapt's `-o` in the
    /// command each run records, on a few reads a route.
    func testEachRouteWritesPlainOutputsExactlyWhenAnAdapterNameRepeats() async throws {
        let nextera = BarcodeKitRegistry.nexteraXTv2
        let nexteraRows = try rows(of: nextera, ["N701-S502", "N702-S503"])
        let onNextera = try definition(["N701-S502,TAAGGCGA,CTCTCTAT", "N702-S503,CGTACTAG,TATCCTCT"], name: "on-nextera",
                                       kitLine: "nextera-xt-v2")
        let custom = try definition(["D01,TGGGCGAA,AGGAGTTA", "D02,GAAGTTGCCG,GGATCTTCCC"], name: "custom")
        let truseq = BarcodeKitRegistry.truseqSingleA
        let (d701, d702) = (truseq.barcodes[0], truseq.barcodes[1])
        let rapid = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "ont-rbk114-24"))

        var bases = DemultiplexDualFormTests.Bases()
        let dualReads = try writeFASTQ(Self.pairReads(nexteraRows, perRow: 50), "dual.fastq")
        let customReads = try writeFASTQ(Self.pairReads(custom.barcodes.map { ($0.id, $0.i7Sequence, $0.i5Sequence ?? "") },
                                                        perRow: 50), "custom.fastq")
        let singleReads = try writeFASTQ((0..<100).map { index -> Read in
            let barcode = index % 2 == 0 ? d701 : d702
            return ("\(barcode.id)|\(index)", barcode.i7Sequence + bases.next(100))
        }, "single.fastq")
        let sheetReads = try writeFASTQ((0..<100).map { index -> Read in
            let barcode = index % 2 == 0 ? d701 : d702
            return ("\(barcode.id)|\(index)", barcode.i7Sequence + bases.next(100) + Self.rc(barcode.i7Sequence))
        }, "sheet.fastq")
        let rapidReads = try writeFASTQ(rapid.barcodes.prefix(2).flatMap { barcode in
            (0..<50).map { index -> Read in
                ("\(barcode.id)|\(index)",
                 PlatformAdapters.ontRapidAdapter + barcode.i7Sequence + PlatformAdapters.ontTransposaseME + bases.next(300))
            }
        }, "rapid.fastq")

        func config(
            _ input: URL, _ kit: BarcodeKitDefinition, location: BarcodeLocation = .bothEnds, symmetry: BarcodeSymmetryMode? = nil,
            distances: (Int, Int) = (0, 0), sheet: [FASTQSampleBarcodeAssignment] = []
        ) -> DemultiplexConfig {
            DemultiplexConfig(
                inputURL: input, barcodeKit: kit,
                outputDirectory: dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true),
                barcodeLocation: location, symmetryMode: symmetry, maxDistanceFrom5Prime: distances.0,
                maxDistanceFrom3Prime: distances.1, trimBarcodes: true, threads: 1, engine: .cutadapt, sampleAssignments: sheet,
                keepsUncheckedSamples: !sheet.isEmpty
            )
        }
        let routes: [(name: String, config: DemultiplexConfig, plain: Bool)] = [
            ("built-in dual at Both Ends 0/0", config(dualReads, nextera), true),
            ("a definition on nextera-xt-v2 at 0/0", config(dualReads, onNextera), true),
            ("built-in dual at Both Ends 3/3", config(dualReads, nextera, distances: (3, 3)), true),
            ("a dual kit with a sample sheet", config(dualReads, nextera, symmetry: .symmetric, sheet: nexteraRows.map {
                FASTQSampleBarcodeAssignment(sampleID: $0.id, forwardSequence: $0.first, reverseSequence: $0.second)
            }), true),
            ("one sample on two barcodes", config(sheetReads, truseq, symmetry: .singleEnd, sheet: [
                FASTQSampleBarcodeAssignment(sampleID: "S1", forwardBarcodeID: d701.id),
                FASTQSampleBarcodeAssignment(sampleID: "S1", forwardBarcodeID: d702.id),
            ]), true),
            ("one barcode a sample in a sheet", config(sheetReads, truseq, symmetry: .singleEnd, sheet: [
                FASTQSampleBarcodeAssignment(sampleID: "S1", forwardBarcodeID: d701.id),
                FASTQSampleBarcodeAssignment(sampleID: "S2", forwardBarcodeID: d702.id),
            ]), false),
            ("single-index at 5' End 0", config(singleReads, truseq, location: .fivePrime), false),
            ("single-index at a 5' Distance of 8", config(singleReads, truseq, location: .fivePrime, distances: (8, 0)), true),
            ("a long-read kit", config(rapidReads, rapid, location: .fivePrime), false),
            ("the observed route of a Custom Definition", config(customReads, custom), true),
        ]
        var seen: [String] = []
        for route in routes {
            do {
                let result = try await DemultiplexingPipeline().run(config: route.config, progress: { _, _ in })
                let pattern = Self.outputPattern(result)
                seen.append("\(route.name): \(pattern ?? "nil")")
                XCTAssertEqual(pattern, route.plain ? "{name}.fastq" : "{name}.fastq.gz", route.name)
            } catch {
                seen.append("\(route.name): threw")
                XCTFail("\(route.name) threw \(error)")
            }
        }
        print("SHAREDNAME routes \(seen)")
    }

    // MARK: - Detect

    /// Detect of a Custom Definition of dual indexes writes each row on two lines, `i7...rc(i5)` and `i5...rc(i7)`
    /// (`runScoutCutadapt`), so a row of 7,000 reads in the scanned reads broke at the base and was counted as none.
    func testDetectOfADualDefinitionCountsEveryReadOfARowPastTheBuffer() async throws {
        let kit = try definition(["D01,TGGGCGAA,AGGAGTTA", "D02,GAAGTTGCCG,GGATCTTCCC"], name: "detect")
        let reads = Self.pairReads(kit.barcodes.map { ($0.id, $0.i7Sequence, $0.i5Sequence ?? "") }, perRow: 7_000)
        let scouted = try await DemultiplexingPipeline().scout(
            inputURL: try writeFASTQ(reads, "detect.fastq"), kit: kit, readLimit: reads.count, progress: { _, _ in }
        )
        let hits = Dictionary(uniqueKeysWithValues: scouted.detections.map { ($0.barcodeID, $0.hitCount) })
        print("SHAREDNAME detect \(hits.sorted { $0.key < $1.key }); scanned \(scouted.readsScanned)")
        XCTAssertEqual(hits, ["D01": 7_000, "D02": 7_000])
    }
}
