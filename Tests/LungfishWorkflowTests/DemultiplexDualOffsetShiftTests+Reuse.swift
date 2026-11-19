// DemultiplexDualOffsetShiftTests+Reuse.swift - The check as the single-barcode and linked routes call it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Fix round FIX-OFFSET-SHIFT of DEMUX-DUAL-OFFSET-SHIFT, item 3. The routes of DEMUX-SINGLE- and DEMUX-LINKED-OFFSET-SHIFT
// write gzip temporaries and trim poly-G on every Illumina and Element kit, and BIO-OFFSET-PAST-DISTANCE adds a look-ahead
// of 4 bases past each distance to the check they share. Each test here is red at 747317157.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

extension DemultiplexDualOffsetShiftTests {
    /// Writes `reads` as cutadapt writes an output and gzips it as `<name>.fastq.gz` in `folder`.
    func writeGzipOutput(_ reads: [Read], named name: String, in folder: URL) throws {
        let plain = folder.appendingPathComponent("\(name).fastq")
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
        try text.write(to: plain, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-f", plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0)
    }

    /// Cutadapt's outputs as `.fastq.gz`, as the single-barcode and linked routes write them: the check reads them, puts
    /// each read in the row that fits it at the fewest errors, and writes each output back as a whole gzip file, one with
    /// no record too. No Cutadapt run: X-5's output holds the two reads that X-5's line further in took (BIO-OFFSET-SHIFT
    /// Q1), each trimmed as that line trims it.
    func testTheCheckReadsAndWritesGzipOutputs() async throws {
        let filler1 = try XCTUnwrap(Self.fillers(Self.x1x5).first { $0.name == "X-1|F3-0" })
        let filler5 = try XCTUnwrap(Self.fillers(Self.x1x5).first { $0.name == "X-5|F3-0" })
        let input = try writeFASTQ([Self.seenF0x9, Self.seenF0x6, filler1, filler5])
        let outputs = dir.appendingPathComponent("gzip-outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        func trimmed(_ read: Read, _ front: Int, _ back: Int) -> Read {
            (read.name, String(read.sequence.dropFirst(front).dropLast(back)))
        }
        try writeGzipOutput([trimmed(Self.seenF0x9, 8, 11), trimmed(Self.seenF0x6, 8, 11), trimmed(filler5, 11, 11)],
                            named: "X-5", in: outputs)
        try writeGzipOutput([trimmed(filler1, 11, 11)], named: "X-1", in: outputs)
        try writeGzipOutput([], named: "unassigned", in: outputs)
        let lines = ">X-1\n^N{3}TGGGCGAA...AGGAGTTAN{3}$\n>X-5\n^N{3}TGGGCGAA...GTAAGGAGN{3}$\n"
        let fit = try XCTUnwrap(AnchoredOffsetFit(adapterFASTA: lines, rowOf: { $0 }, errorRate: 0.15, indels: true))
        let counts = try DemultiplexOffsetShiftPass(
            inputFASTQ: input, outputDirectory: outputs, unassignedName: "unassigned", fit: fit, trims: true
        ).run()
        XCTAssertEqual(counts.moved, 1)
        XCTAssertEqual(counts.ambiguous, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: outputs.path).sorted()
        XCTAssertEqual(files, ["X-1.fastq.gz", "X-5.fastq.gz", "unassigned.fastq.gz"])
        var rows: [String: [Read]] = [:]
        for name in ["X-1", "X-5", "unassigned"] {
            let url = outputs.appendingPathComponent("\(name).fastq.gz")
            let magic = try XCTUnwrap(FileHandle(forReadingFrom: url).read(upToCount: 2))
            XCTAssertEqual([UInt8](magic), [0x1F, 0x8B], "\(name) is still gzip")
            rows[name] = try await records(url)
        }
        XCTAssertEqual(rows["X-1"]?.map(\.name), ["X-1|seen|F0|6", "X-1|F3-0"])
        XCTAssertEqual(rows["X-1"]?.first?.sequence, String(Self.seenF0x6.sequence.dropFirst(8).dropLast(8)))
        XCTAssertEqual(rows["X-5"]?.map(\.name), ["X-5|F3-0"])
        XCTAssertEqual(rows["unassigned"]?.map(\.name), ["X-1|seen|F0|9"])
        XCTAssertEqual(rows["unassigned"]?.first?.sequence, Self.seenF0x9.sequence, "a tied read goes to Unassigned whole")
    }

    /// A run that trims poly-G (`--nextseq-trim=20`, every Illumina and Element kit): reads (a) and (b) with a tail of 10
    /// G's, which Cutadapt cuts before it searches. The check reads each read as cut, so X-1's reads 9 go to Unassigned and
    /// are counted and its reads 6 stay in X-1, trimmed to their inserts, as they do with no tail. Read as sequenced, the
    /// tail puts X-1's second barcode out of reach and the reads would stay in X-5.
    func testARunThatTrimsPolyGChecksEachReadAsCutadaptCutIt() async throws {
        let tail = String(repeating: "G", count: 10)
        let named = [Self.seenF0x9, Self.seenR0x9, Self.seenF0x6, Self.seenR0x6]
        let reads = named.map { ($0.name, $0.sequence + tail) } + Self.fillers(Self.x1x5)
        let output = dir.appendingPathComponent("demux-\(UUID().uuidString)", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: try writeFASTQ(reads), barcodeKit: try kit(Self.x1x5), outputDirectory: output,
            barcodeLocation: .bothEnds, errorRate: 0.15, maxDistanceFrom5Prime: 3, maxDistanceFrom3Prime: 3,
            trimBarcodes: true, polyGTrimQuality: 20, threads: 1
        )
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        XCTAssertTrue(result.manifest.parameters.commandLine?.contains("--nextseq-trim=20") ?? false)
        var rows: [String: [Read]] = [:]
        for barcode in result.manifest.barcodes {
            let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            rows[barcode.barcodeID] = try await records(try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle)))
        }
        var unassigned: [String] = []
        if let bundle = result.unassignedBundleURL, let fastq = FASTQBundle.resolvePrimaryFASTQURL(for: bundle) {
            unassigned = try await records(fastq).map(\.name)
        }
        print("OFFSETSHIFT poly-G: X-1 \(rows["X-1"]?.count ?? 0), X-5 \(rows["X-5"]?.count ?? 0), unassigned \(unassigned), "
              + "ambiguousReads \(Self.ambiguous(result))")
        XCTAssertEqual(unassigned.sorted(), ["X-1|seen|F0|9", "X-1|seen|R0|9"])
        XCTAssertEqual(Self.ambiguous(result), "2")
        for read in [Self.seenF0x6, Self.seenR0x6] {
            let placed = rows["X-1"]?.first { $0.name == read.name }
            XCTAssertEqual(placed?.sequence, String(read.sequence.dropFirst(8).dropLast(8)), read.name)
        }
        XCTAssertEqual(rows["X-5"]?.filter { !$0.name.hasPrefix("X-5|") }.map(\.name) ?? [], [])
    }

    // MARK: - Past the distance (BIO-OFFSET-PAST-DISTANCE item 2)

    /// Rows X-1 and Z, `GTGGGCGA`/`GGAGTTAT`, at 1/1 and error 0 and 0.15. X-1's pair sits 2 bases in, past the distance,
    /// and Z's pair is the read's bases 1 in at both ends. Z fits within the distance alone and X-1 fits as well 1 base
    /// past it, so the read and its other strand go to Unassigned and are counted, where the check kept them in Z.
    /// Fillers of both rows with their pairs at the read ends stay in their rows.
    func testAReadThatItsOwnRowFitsJustPastTheDistanceGoesToUnassigned() async throws {
        let rows: [Row] = [("X-1", "TGGGCGAA", "AGGAGTTA"), ("Z", "GTGGGCGA", "GGAGTTAT")]
        let forward = "AG" + "TGGGCGAA" + "GATTACAGATTACAGATTACA" + "AGGAGTTA" + "TC"
        let named: [Read] = [("X-1|past|F", forward), ("X-1|past|R", Self.rc(forward))]
        var bases = DemultiplexDualFormTests.Bases(state: 0x2A)
        let fillers = rows.flatMap { row in
            (0..<5).flatMap { index -> [Read] in
                let read = row.first + "C" + bases.next(40) + "C" + row.second
                return [("\(row.name)|F0-\(index)", read), ("\(row.name)|R0-\(index)", Self.rc(read))]
            }
        }
        for errorRate in [0.0, 0.15] {
            let label = "past 1/1 e \(errorRate)"
            let outcome = try await run(rows, named + fillers, distance: 1, errorRate: errorRate)
            report(label, outcome, named.map(\.name))
            for read in named { XCTAssertEqual(outcome.row(of: read.name), "Unassigned", "\(label): \(read.name)") }
            XCTAssertEqual(outcome.ambiguous, "2", label)
            XCTAssertEqual(outcome.unassignedCount, 2, label)
            XCTAssertEqual(outcome.wrong, [], label)
            XCTAssertEqual(outcome.placed.values.map(\.count).reduce(0, +), 20, label)
        }
    }

    /// The 1,680 reads of `q2-nextera-xt-v2-random.fastq` (BIO-OFFSET-SHIFT Q2) whose pairs sit 4 bases in, 1 past 3/3,
    /// on the 84 rows of nextera-xt-v2 as a Custom Definition at e 0.15. Cutadapt put 18 in another row and the check kept
    /// 14 there. Now none is in another row, and at least 1,266 stay in their own (BIO-OFFSET-PAST-DISTANCE Q2, 1,266/0/414
    /// modelled).
    func testNexteraReadsJustPastTheDistanceLandInNoOtherRow() async throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let input = tests.appendingPathComponent("Fixtures/demux-dual-offset-shift/nextera-xt-v2-random-l4.fastq")
        let outcome = try await run(Self.nextera, input, distance: 3, errorRate: 0.15)
        let placed = outcome.placed.values.map(\.count).reduce(0, +)
        report("past L4 3/3 e 0.15", outcome, [])
        print("OFFSETSHIFT past L4: placed \(placed), wrong \(outcome.wrong)")
        XCTAssertEqual(outcome.wrong, [])
        XCTAssertGreaterThanOrEqual(placed, 1_266)
        XCTAssertEqual(placed + outcome.unassignedCount, 1_680)
    }
}
