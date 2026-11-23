// BuildDbTaxTriageRebuildKeepsSamplesTests.swift - A forced rebuild never drops a sample of the database it replaces (3.2 TTREADS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ARCH should-fix 3 of lane TTREADS. A sample whose organism report holds no row, such as a blank with Kraken-only hits,
// takes its rows from `top/<sample>.top_report.tsv`. The command's `.legacy` cleanup removed `top/` after the build, so
// a second build with `--force`, which the app now runs for every database an older Lungfish counted, finds no rows for
// that sample and replaced the database without it. A control then read as clean, and the first database was gone.
// TTREADS made that rebuild throw, so the result could never be recounted. Since lane TT-m1 the cleanup keeps `top/`,
// and a folder an older build left without it keeps the earlier database's rows of the sample, named as not recounted.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbTaxTriageRebuildKeepsSamplesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageRebuildKeepsSamples")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at 10c4e49e4 if the second build drops B. Since TT-m1 the first build keeps `B/top/`, and the case removes it as
    /// an older build's cleanup did. The second build then keeps B's rows as the first database held them, says so in
    /// words that name B, and names B as not recounted in the database.
    func testForceRebuildAfterLegacyCleanupKeepsAKrakenOnlySample() async throws {
        let batch = try makeBatch()
        let databaseURL = batch.appendingPathComponent("taxtriage.sqlite")
        let globalOptions = try GlobalOptions.parse([])

        _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(
            in: batch, options: BuildDbRunOptions(globalOptions: globalOptions), events: .silent
        )
        let firstSamples = try TaxTriageDatabase(at: databaseURL).fetchSamples().map(\.sample).sorted()
        XCTAssertEqual(firstSamples.count, 2, "the first build reads A from its report and B from top/: \(firstSamples)")
        XCTAssertTrue(firstSamples.contains("B"), "B is in the first database: \(firstSamples)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.appendingPathComponent("B/top").path), "the legacy cleanup keeps top/")
        let firstRows = try TaxTriageDatabase(at: databaseURL).fetchRows(samples: ["B"]).map { "\($0.organism)|\($0.readsAligned)" }
        try FileManager.default.removeItem(at: batch.appendingPathComponent("B/top", isDirectory: true))

        var again = BuildDbRunOptions(globalOptions: globalOptions)
        again.force = true
        let warnings = WarningLines()
        let events = BuildDbEventSink(progress: { _, _ in }, text: { _ in }, textWarning: { _ in }, warning: { warnings.append($0) })
        _ = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(in: batch, options: again, events: events)

        let words = warnings.lines.joined(separator: "\n")
        XCTAssertTrue(words.contains("Kept the rows of B from the earlier taxtriage.sqlite without recounting them"), words)
        let database = try TaxTriageDatabase(at: databaseURL)
        XCTAssertEqual(try database.fetchSamples().map(\.sample).sorted(), firstSamples, "the forced rebuild kept every sample")
        XCTAssertEqual(try database.fetchRows(samples: ["B"]).map { "\($0.organism)|\($0.readsAligned)" }, firstRows)
        XCTAssertEqual(try database.fetchMetadata()[BuildDbCommand.TaxTriageSubcommand.notRecountedSamplesMetadataKey], "[\"B\"]")
        let sidecar = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: databaseURL)))
        XCTAssertFalse(sidecar.steps.contains { ($0.exitStatus ?? 0) != 0 }, "the rebuild completed")
    }

    /// The warning lines a build gave, from the sink's `warning`.
    private final class WarningLines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var lines: [String] { lock.withLock { stored } }
        func append(_ line: String) { lock.withLock { stored.append(line) } }
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
