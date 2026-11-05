// BuildDbTaxTriageRebuildKeepsSamplesTests.swift - A forced rebuild never drops a sample of the database it replaces (3.2 TTREADS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ARCH should-fix 3 of lane TTREADS. A sample whose organism report holds no row, such as a blank with Kraken-only hits,
// takes its rows from `top/<sample>.top_report.tsv`. The command's `.legacy` cleanup removes `top/` after the build, so
// a second build with `--force`, which the app now runs for every database an older Lungfish counted, finds no rows for
// that sample and replaced the database without it. A control then read as clean, and the first database was gone.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbTaxTriageRebuildKeepsSamplesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageRebuildKeepsSamples")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at 10c4e49e4 if the second build drops B. Either B is still in the database, or the second build throws
    /// and the first database is back.
    func testForceRebuildAfterLegacyCleanupKeepsAKrakenOnlySample() async throws {
        let batch = try makeBatch()
        let databaseURL = batch.appendingPathComponent("taxtriage.sqlite")
        let events = BuildDbEventSink(progress: { _, _ in }, text: { _ in }, textWarning: { _ in }, warning: { _ in })
        let globalOptions = try GlobalOptions.parse([])

        _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(
            in: batch, options: BuildDbRunOptions(globalOptions: globalOptions), events: events
        )
        let firstSamples = try TaxTriageDatabase(at: databaseURL).fetchSamples().map(\.sample).sorted()
        XCTAssertEqual(firstSamples.count, 2, "the first build reads A from its report and B from top/: \(firstSamples)")
        XCTAssertTrue(firstSamples.contains("B"), "B is in the first database: \(firstSamples)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("B/top").path), "the legacy cleanup removed top/")

        var again = BuildDbRunOptions(globalOptions: globalOptions)
        again.force = true
        do {
            _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(in: batch, options: again, events: events)
        } catch {
            // A refusal is right if it leaves the first database whole.
        }

        let samples = try TaxTriageDatabase(at: databaseURL).fetchSamples().map(\.sample).sorted()
        XCTAssertEqual(samples, firstSamples, "the forced rebuild kept every sample of the database it replaced")
    }

    /// A batch of sample A, with an organism report that holds a row, and sample B, whose organism report holds its
    /// header alone and whose only rows are in `top/B.top_report.tsv`.
    private func makeBatch() throws -> URL {
        let batch = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        let sampleA = BuildDbStreamCapture.fixturesFolder
            .appendingPathComponent("taxtriage-odr-3.3.8/SRR12486983", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sampleA, to: batch.appendingPathComponent("SRR12486983", isDirectory: true))

        let report = try String(contentsOf: sampleA.appendingPathComponent("report/SRR12486983.odr.txt"), encoding: .utf8)
        let header = try XCTUnwrap(report.components(separatedBy: "\n").first, "the fixture report holds a header")
        let reportFolder = batch.appendingPathComponent("B/report", isDirectory: true)
        let topFolder = batch.appendingPathComponent("B/top", isDirectory: true)
        try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: topFolder, withIntermediateDirectories: true)
        try Data((header + "\n").utf8).write(to: reportFolder.appendingPathComponent("B.odr.txt"))
        let top = "abundance\tclade_fragments_covered\tnumber_fragments_assigned\trank\ttaxid\tname\n"
            + "0.5\t7.0\t7.0\tS\t3052040\tBocaparvovirus primate1\n"
        try Data(top.utf8).write(to: topFolder.appendingPathComponent("B.top_report.tsv"))
        return batch
    }
}
