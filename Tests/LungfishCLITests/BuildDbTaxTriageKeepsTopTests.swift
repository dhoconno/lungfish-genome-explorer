// BuildDbTaxTriageKeepsTopTests.swift - Opening an older TaxTriage result never deletes top/ (TT-LEGACY-CLEANUP-REMOVES-TOP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep before Preview 2026.11.17, lane TT-m1. A TaxTriage folder with no record of `taxtriage run` (an older run or
// an import) took the command's `.legacy` cleanup, which removed `top/` too, the only file source of a sample whose rows
// came from `top/<sample>.top_report.tsv`. The app ran that build each time it recounted such a result on display, so
// the first open deleted the folder, and every later rebuild refused because it would lose the sample (3.2 TTREADS).
// The cleanup now keeps `top/` as the executor's does, and a rebuild of a folder that an older build left without it
// keeps the earlier database's rows of each sample no report holds, marked as not recounted (folds
// TT-OLD-RESULT-CANNOT-RECOUNT). The runs use `taxtriage-mini` without `minimap2/` and `taxtriage-odr-3.3.8`, as
// `BuildDbTaxTriageIndexTests` does, so no row names a BAM and no samtools runs.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbTaxTriageKeepsTopTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "build-db-taxtriage-keeps-top")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func fixture(_ name: String) -> URL {
        BuildDbStreamCapture.fixturesFolder.appendingPathComponent(name, isDirectory: true)
    }

    /// A sample folder of `taxtriage-mini` without its BAMs or its report, so its rows come only from
    /// `top/SRR35517702.top_report.tsv`, with a file in `count/` that the cleanup removes.
    private func makeTopOnlySample(at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: fixture("taxtriage-mini"), to: destination)
        for folder in ["minimap2", "report"] {
            try fileManager.removeItem(at: destination.appendingPathComponent(folder, isDirectory: true))
        }
        let count = destination.appendingPathComponent("count/SRR35517702.fastq.gz")
        try fileManager.createDirectory(at: count.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("reads\n".utf8).write(to: count)
    }

    private func options(force: Bool, noCleanup: Bool = false) throws -> BuildDbRunOptions {
        BuildDbRunOptions(force: force, noCleanup: noCleanup, globalOptions: try GlobalOptions.parse([]))
    }

    private func exists(_ relative: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path)
    }

    /// Each row of `samples` in `result`'s database with the numbers a person reads, in the order the database keeps them.
    private func rowSummary(in result: URL, samples: [String]) throws -> [String] {
        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        return try database.fetchRows(samples: samples).map { row in
            [
                row.sample, row.organism, row.taxId.map(String.init) ?? "nil", String(format: "%.4f", row.tassScore),
                String(row.readsAligned), row.uniqueReads.map(String.init) ?? "nil", row.primaryAccession ?? "nil",
                row.bamPath ?? "nil",
            ].joined(separator: "|")
        }
    }

    // MARK: - Item 2, the legacy cleanup keeps top/

    /// A folder with no record of `taxtriage run` and one sample whose rows come only from `top/`. Its `--force` build
    /// runs the command's cleanup, which removes `count/` and keeps `top/`, as the executor's cleanup does.
    func testLegacyBuildKeepsTop() async throws {
        let result = root.appendingPathComponent("taxtriage", isDirectory: true)
        try makeTopOnlySample(at: result)
        XCTAssertNil(BuildDbCommand.TaxTriageSubcommand.executorRecord(in: result), "the folder holds no record of taxtriage run")

        _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(in: result, options: try options(force: true), events: .silent)

        XCTAssertFalse(exists("count", in: result), "the cleanup ran and removed count/")
        XCTAssertTrue(exists("top/SRR35517702.top_report.tsv", in: result), "the legacy cleanup keeps top/")
        let samples = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite")).fetchSamples().map(\.sample)
        XCTAssertEqual(samples, ["SRR35517702"])
    }

    // MARK: - Item 3, a folder that already lost top/

    /// A database that holds sample SRR35517702, whose rows came from `B/top/`, and a folder that no longer holds that
    /// report, as an older build's cleanup left it. The rebuild keeps the sample's rows and counts as the database held
    /// them, names the sample as not recounted in the database's metadata, and reads A from its report again.
    func testRebuildWithoutTopKeepsOldSampleRows() async throws {
        let batch = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("taxtriage-odr-3.3.8").appendingPathComponent("SRR12486983", isDirectory: true),
            to: batch.appendingPathComponent("A", isDirectory: true)
        )
        try makeTopOnlySample(at: batch.appendingPathComponent("B", isDirectory: true))
        _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(
            in: batch, options: try options(force: false, noCleanup: true), events: .silent
        )
        let held = try rowSummary(in: batch, samples: ["SRR35517702"])
        XCTAssertFalse(held.isEmpty, "the first build reads SRR35517702 from B/top/")
        try FileManager.default.removeItem(at: batch.appendingPathComponent("B/top", isDirectory: true))

        do {
            _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(
                in: batch, options: try options(force: true), events: .silent
            )
        } catch {
            return XCTFail("the rebuild of a folder that lost top/ threw: \(error)")
        }

        let database = try TaxTriageDatabase(at: batch.appendingPathComponent("taxtriage.sqlite"))
        XCTAssertEqual(try database.fetchSamples().map(\.sample).sorted(), ["SRR12486983", "SRR35517702"])
        XCTAssertEqual(try rowSummary(in: batch, samples: ["SRR35517702"]), held, "the rows and counts the database held")
        let metadata = try database.fetchMetadata()
        XCTAssertEqual(metadata["not_recounted_samples"], "[\"SRR35517702\"]", "the database names the sample it did not recount")
        XCTAssertFalse(database.isStale(forResultDirectory: batch), "the app does not recount it again on every open")
    }
}
