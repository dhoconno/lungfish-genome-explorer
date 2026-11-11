// BuildDbTaxTriageBAMFitTests.swift - build-db never records another sample's BAM, and marks a BAM it fitted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 close, lane BUILDDB-FIX, row BUILDDB-BAM-FIT (S1 by effect, BIO). When a sample's own BAM was gone from a
// `minimap2/` folder that holds several samples, `build-db taxtriage` recorded any file whose name held the sample id,
// such as `S1_2.S1_2.dwnld.references.bam` for sample S1, and kept no mark of the fit. Unique Reads, the alignment view
// and every Extract Reads route then read another sample's reads, and no route said so (`SCR rulings/WALK-BIO.md` 1.1
// and 1.2). The tests are BIO's two (1.4 (b) item 3) and QA's addition 1 (`SCR rulings/BUILDDB-QA.md` section 4). The
// files hold no reads, and with no `combine/` gcfmap no row has an accession, so the unique-read pass reads no BAM.

import XCTest
import SQLite3
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbTaxTriageBAMFitTests: XCTestCase {
    private static let sentence = "Sample S1's own BAM was not found, so Lungfish read S1_2.bam, the one file in the "
        + "minimap2 folder that fits its name. If that file belongs to another sample, put S1's own BAM back and try again."

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageBAMFit")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// BIO 1.4 (b) item 3. Reports for S1 and S1_2, and only S1_2's two files in `minimap2/`. Red at P, which records
    /// `minimap2/S1_2.S1_2.dwnld.references.bam` (score 30) as S1's BAM, from the organism reports and from `top/`.
    func testFittedBAMOfAnotherSampleIsNotRecorded() async throws {
        for layout in [ReportLayout.organismReport, .topReport] {
            let result = root.appendingPathComponent("another-\(layout)", isDirectory: true)
            for sample in ["S1", "S1_2"] { try writeReport(layout, sample: sample, in: result) }
            try place(["S1_2.S1_2.dwnld.references.bam", "S1_2.bam"], in: result)

            let built = try await build(result)
            let s1Rows = try built.database.fetchRows(samples: ["S1"])
            XCTAssertFalse(s1Rows.isEmpty, "\(layout): S1 has rows")
            for row in s1Rows { XCTAssertNil(row.bamPath, "\(layout): S1 records no BAM of another sample") }
            for row in try built.database.fetchRows(samples: ["S1_2"]) {
                XCTAssertEqual(row.bamPath, "minimap2/S1_2.S1_2.dwnld.references.bam", "\(layout): S1_2 keeps its own")
            }
            XCTAssertEqual(try fittedSamples(built.database), [], "\(layout): no sample's BAM was fitted")
        }
    }

    /// A sibling's files in a subfolder of `minimap2/` are refused as in the folder itself (BIO review SF-2). Red at P,
    /// which records `minimap2/sub/S1_2.S1_2.dwnld.references.bam` (score 30) for S1. S1_2 takes `sub/S1_2.bam` (score
    /// 10), because the exact-name return looks at the direct children of `minimap2/` alone and the lower score wins;
    /// the review expected the pipeline name there, which the score order does not give (the run at the head said so).
    func testSiblingBAMInASubfolderOfMinimap2IsNotRecorded() async throws {
        let result = root.appendingPathComponent("subfolder", isDirectory: true)
        for sample in ["S1", "S1_2"] { try writeReport(.organismReport, sample: sample, in: result) }
        try place(["sub/S1_2.S1_2.dwnld.references.bam", "sub/S1_2.bam"], in: result)
        let built = try await build(result)
        let s1Rows = try built.database.fetchRows(samples: ["S1"])
        XCTAssertFalse(s1Rows.isEmpty, "S1 has rows")
        for row in s1Rows { XCTAssertNil(row.bamPath, "S1 records no BAM of another sample") }
        for row in try built.database.fetchRows(samples: ["S1_2"]) {
            XCTAssertEqual(row.bamPath, "minimap2/sub/S1_2.bam", "S1_2 keeps a file of its own in the subfolder")
        }
        XCTAssertEqual(try fittedSamples(built.database), [], "S1_2's file has the pipeline's name, S1 has none")
    }

    /// BIO 1.4 (b) item 3. Reports for S1 alone and `minimap2/S1_2.bam`, a file whose name fits S1 and no other sample
    /// of the result. The build still records it, says so in one line and marks S1 as fitted in the metadata, and an
    /// extraction from the database says the scan's sentence by either form of the result path. Red at P, which
    /// records the file with no line, no mark and no sentence.
    func testLoneFittedBAMIsMarked() async throws {
        let result = try makeLoneFitResult()
        let built = try await build(result)
        let rows = try built.database.fetchRows(samples: ["S1"])
        XCTAssertFalse(rows.isEmpty, "S1 has rows")
        for row in rows { XCTAssertEqual(row.bamPath, "minimap2/S1_2.bam", "the lone fit is recorded") }

        let fitLines = built.lines.filter { $0.contains("minimap2/S1_2.bam") }
        XCTAssertEqual(fitLines.count, 1, "one build line for the fitted sample: \(built.lines)")
        XCTAssertTrue(fitLines.first?.hasPrefix("Sample S1's own BAM was not found") == true, "\(fitLines)")
        XCTAssertEqual(try fittedSamples(built.database), ["S1"], "the metadata lists S1 as fitted")

        for resultPath in [result, result.appendingPathComponent("taxtriage.sqlite")] {
            let bam = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: "S1", resultPath: resultPath
            )
            XCTAssertEqual(bam.lastPathComponent, "S1_2.bam", "the recorded path is read")
            XCTAssertEqual(
                ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1", resultPath: resultPath, bam: bam),
                Self.sentence, "result path \(resultPath.lastPathComponent)"
            )
        }
    }

    /// QA addition 1. Issue #22's downsampled MiniBAM names for two samples whose ids share a prefix. Red at P, where
    /// both files score 20 for S1 and the tie records no BAM. Refusing another sample's file keeps issue #22's layout
    /// working for both samples.
    func testDownsampledMiniBAMsOfPrefixSharingSamplesResolveEach() async throws {
        let result = root.appendingPathComponent("minibam", isDirectory: true)
        for sample in ["S1", "S1_2"] { try writeReport(.organismReport, sample: sample, in: result) }
        try place([
            "S1.downsampled.minibam.bam", "S1.downsampled.minibam.bam.bai",
            "S1_2.downsampled.minibam.bam", "S1_2.downsampled.minibam.bam.bai",
        ], in: result)

        let built = try await build(result)
        for sample in ["S1", "S1_2"] {
            let rows = try built.database.fetchRows(samples: [sample])
            XCTAssertFalse(rows.isEmpty, "\(sample) has rows")
            for row in rows {
                XCTAssertEqual(row.bamPath, "minimap2/\(sample).downsampled.minibam.bam", sample)
                XCTAssertEqual(row.bamIndexPath, "minimap2/\(sample).downsampled.minibam.bam.bai", sample)
            }
        }
        XCTAssertEqual(try fittedSamples(built.database), ["S1", "S1_2"], "neither file has a name the pipeline gives")
    }

    /// A database that an older build made holds no fitted mark. It keeps its recorded path, and the extraction reads
    /// that path with no sentence, as at P, until the database is built again. Green at P and at the fix.
    func testADatabaseOfAnOlderBuildKeepsItsPathWithNoSentence() async throws {
        let result = try makeLoneFitResult()
        _ = try await build(result)
        let databaseURL = result.appendingPathComponent("taxtriage.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM metadata WHERE key = 'fitted_bam_samples'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let bam = try await ClassifierReadResolver().testingResolveBAMURL(tool: .taxtriage, sampleId: "S1", resultPath: result)
        XCTAssertEqual(bam.lastPathComponent, "S1_2.bam", "the recorded path stays")
        XCTAssertNil(ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1", resultPath: result, bam: bam))
    }

    // MARK: - Fixtures

    private enum ReportLayout {
        case organismReport
        case topReport
    }

    /// Reports for S1 alone and `minimap2/S1_2.bam`.
    private func makeLoneFitResult() throws -> URL {
        let result = root.appendingPathComponent("lone", isDirectory: true)
        try writeReport(.organismReport, sample: "S1", in: result)
        try place(["S1_2.bam"], in: result)
        return result
    }

    /// One sample's report, `report/<sample>.odr.txt` from the header and first row of the 3.3.8 fixture with the
    /// row's Specimen ID set to the sample, or `top/<sample>.top_report.tsv` with one species row.
    private func writeReport(_ layout: ReportLayout, sample: String, in result: URL) throws {
        let url: URL
        let content: String
        switch layout {
        case .organismReport:
            let fixture = BuildDbStreamCapture.fixturesFolder
                .appendingPathComponent("taxtriage-odr-3.3.8/SRR12486983/report/SRR12486983.odr.txt")
            let lines = try String(contentsOf: fixture, encoding: .utf8).components(separatedBy: "\n")
            let specimen = try XCTUnwrap(lines[0].components(separatedBy: "\t").firstIndex(of: "Specimen ID"))
            var row = lines[1].components(separatedBy: "\t")
            row[specimen] = sample
            url = result.appendingPathComponent("report/\(sample).odr.txt")
            content = lines[0] + "\n" + row.joined(separator: "\t") + "\n"
        case .topReport:
            url = result.appendingPathComponent("top/\(sample).top_report.tsv")
            content = "abundance\tclade_fragments_covered\tnumber_fragments_assigned\trank\ttaxid\tname\n"
                + "0.01\t31.0\t30.0\tS\t2697049\tSevere acute respiratory syndrome coronavirus 2\n"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Files under `minimap2/` that hold no reads.
    private func place(_ names: [String], in result: URL) throws {
        let minimap2 = result.appendingPathComponent("minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2, withIntermediateDirectories: true)
        for name in names {
            let file = minimap2.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("BAM".utf8).write(to: file)
        }
    }

    /// Builds the result's database with no cleanup and returns it with every line the build wrote.
    private func build(_ result: URL) async throws -> (database: TaxTriageDatabase, lines: [String]) {
        let lines = BuildLines()
        let events = BuildDbEventSink(
            progress: { _, _ in }, text: { lines.add($0) }, textWarning: { lines.add($0) }, warning: { lines.add($0) }
        )
        var options = BuildDbRunOptions(globalOptions: try GlobalOptions.parse([]))
        options.noCleanup = true
        _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(in: result, options: options, events: events)
        return (try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite")), lines.all)
    }

    /// The sample ids that the database's metadata marks as fitted. A database with no mark fails the test.
    private func fittedSamples(_ database: TaxTriageDatabase) throws -> [String] {
        let value = try XCTUnwrap(try database.fetchMetadata()["fitted_bam_samples"], "the build records its fitted samples")
        return try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }
}

/// The lines of one build, which the sink may send from another task.
private final class BuildLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
