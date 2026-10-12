// BuildDbTaxTriageIndexTests.swift - The build-db taxtriage core as TaxTriage on the executor indexes with it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A2 M3, with B12 M2 and BIO 8. Decision T5 of Phase 2.8 gives the executor path a cleanup that keeps
// `top/` and records its removal after the build step, and keeps today's cleanup for the legacy route, so row 258's
// `--force` rebuild is pinned on both. Serial sample folders are read in byte order of their names (BIO 8, 2.7 E8).
// The runs use `taxtriage-mini` without `minimap2/` and `taxtriage-odr-3.3.8`, as `BuildDbTaxTriageCleanupFreezeTests`
// does, so no row names a BAM and no samtools runs.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbTaxTriageIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "build-db-taxtriage-index")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Files of a finished sample folder that either cleanup removes, `top/` aside.
    private static let removedSeed = [
        "count/S.fastq.gz", "fastp/S.fastp.fastq.gz", "fastp/S_1.fastq", "filterkraken/S.report.txt", "get/S.get.tsv",
        "map/S.taxid.tsv", "samtools/S.stats.txt", "bedtools/S.cov.tsv", "mergedsubspecies/S.tsv",
        "mergedkrakenreport/S.report.txt",
    ]

    /// Files beside them that no cleanup removes.
    private static let keptSeed = ["fastp/S.fastp.html", "fastp/nested/S.nested.fastq.gz", "krona/S.krona.html"]

    private func fixture(_ name: String) -> URL {
        BuildDbStreamCapture.fixturesFolder.appendingPathComponent(name, isDirectory: true)
    }

    /// A sample folder of `taxtriage-mini` without its BAMs. With `topOnly` its rows come only from `top/`.
    private func makeMini(at destination: URL, topOnly: Bool = false, seeded: Bool = true) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: fixture("taxtriage-mini"), to: destination)
        try fileManager.removeItem(at: destination.appendingPathComponent("minimap2", isDirectory: true))
        if topOnly {
            try fileManager.removeItem(at: destination.appendingPathComponent("report", isDirectory: true))
        }
        guard seeded else { return }
        for relative in Self.removedSeed + Self.keptSeed {
            let url = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(relative)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func makeODR(at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("taxtriage-odr-3.3.8").appendingPathComponent("SRR12486983", isDirectory: true),
            to: destination
        )
    }

    private func buildDb(_ result: URL, _ arguments: [String]) async throws {
        try await BuildDbCommand.TaxTriageSubcommand.parse([result.path] + arguments).run()
    }

    private func index(_ result: URL, layout: AnalysisRunLayout) async throws -> AnalysisResultIndex {
        try await TaxTriageResultIndexer().buildIndex(
            AnalysisResultIndexRequest(toolID: .taxtriage, resultDirectory: result, layout: layout)
        )
    }

    /// The samples of the database's rows, each where its first row was written.
    private func rowSamples(in result: URL) throws -> [String] {
        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let samples = try database.fetchSamples().map(\.sample)
        var seen: [String] = []
        for row in try database.fetchRowsPage(samples: samples, limit: 10_000, offset: 0).rows where !seen.contains(row.sample) {
            seen.append(row.sample)
        }
        return seen
    }

    /// `path` below `directory`, whose real path may start with `/private` (`resolvingSymlinksInPath` drops it).
    private func relative(_ path: String, to directory: URL) -> String? {
        for prefix in [directory.path, "/private" + directory.path] where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return nil
    }

    private func exists(_ relative: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path)
    }

    // MARK: - BIO 8

    /// `S10` comes before `S2` in byte order and after it in Finder's order, so the rows of the folder `S10` come first.
    func testSerialSampleFoldersAreReadInByteOrder() async throws {
        let batch = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        try makeMini(at: batch.appendingPathComponent("S2", isDirectory: true), seeded: false)
        try makeODR(at: batch.appendingPathComponent("S10", isDirectory: true))

        try await buildDb(batch, ["--force", "--no-cleanup", "-q"])

        let samples = try rowSamples(in: batch)
        XCTAssertEqual(samples.first, "SRR12486983", "\(samples)")
        XCTAssertEqual(Set(samples), ["SRR12486983", "SRR35517702", "SRR35517703", "SRR35517705"])
    }

    // MARK: - Row 258, the legacy route

    /// Today's cleanup removes `top/`, so a `--force` rebuild of a result whose only rows came from there throws and
    /// keeps its database, and a batch loses that sample's rows. The legacy route keeps this until it goes (T5).
    func testAForceRebuildAfterTheLegacyCleanupLosesRowsThatCameOnlyFromTop() async throws {
        let single = root.appendingPathComponent("taxtriage", isDirectory: true)
        try makeMini(at: single, topOnly: true)
        try await buildDb(single, ["--force", "-q"])
        XCTAssertFalse(exists("top", in: single))
        let database = try Data(contentsOf: single.appendingPathComponent("taxtriage.sqlite"))
        do {
            try await buildDb(single, ["--force", "-q"])
            XCTFail("a rebuild with no report left throws")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: single.appendingPathComponent("taxtriage.sqlite")), database, "it keeps its database")

        let batch = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        try makeODR(at: batch.appendingPathComponent("A", isDirectory: true))
        try makeMini(at: batch.appendingPathComponent("B", isDirectory: true), topOnly: true)
        try await buildDb(batch, ["--force", "-q"])
        XCTAssertEqual(try rowSamples(in: batch), ["SRR12486983", "SRR35517702"])
        try await buildDb(batch, ["--force", "-q"])
        XCTAssertEqual(try rowSamples(in: batch), ["SRR12486983"], "the rows of B came only from top/")
    }

    // MARK: - T5, the executor path

    /// The executor's index keeps `top/`, removes the rest of the cleanup list, writes no record at the root, and its
    /// removal step names each removed file with its digest after the build step.
    func testTheExecutorsIndexKeepsTopAndRecordsItsRemovalAfterTheBuild() async throws {
        let result = root.appendingPathComponent("taxtriage-batch-1", isDirectory: true)
        try makeMini(at: result)

        let index = try await index(result, layout: .sharedBatchRoot)

        XCTAssertEqual(index.outputs.map(\.url.lastPathComponent), ["taxtriage.sqlite"])
        XCTAssertEqual(index.outputs.map(\.role), [.index])
        XCTAssertEqual(index.steps.suffix(2).map(\.toolName), ["lungfish build-db taxtriage", BuildDbCommand.TaxTriageSubcommand.cleanupRemovalToolName])
        let removal = try XCTUnwrap(index.steps.last)
        XCTAssertEqual(removal.resolvedOptions["operation"], .string(RecordedRemovalStep.operation))
        let removed = removal.inputs.compactMap { relative($0.path, to: result) }
        XCTAssertEqual(removed.count, removal.inputs.count, "every removed file is inside the result, \(removal.inputs.map(\.path))")
        XCTAssertEqual(Set(removed), Set(Self.removedSeed))
        XCTAssertEqual(removed.count, Self.removedSeed.count, "each file once")
        XCTAssertTrue(removal.inputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertEqual(removal.outputs, [])
        for relative in Self.removedSeed {
            XCTAssertFalse(exists(relative, in: result), relative)
        }
        for relative in Self.keptSeed + ["top/SRR35517702.top_report.tsv", "report/multiqc_data/multiqc_confidences.txt"] {
            XCTAssertTrue(exists(relative, in: result), relative)
        }
        let build = try XCTUnwrap(index.steps.first { $0.toolName == "lungfish build-db taxtriage" })
        XCTAssertTrue(build.inputs.contains { $0.path.hasSuffix("top/SRR35517702.top_report.tsv") })
        XCTAssertFalse(exists(ProvenanceRecorder.provenanceFilename, in: result), "the executor writes the root record")
        XCTAssertTrue(exists("taxtriage.sqlite.lungfish-provenance.json", in: result))
    }

    /// Row 258 on the executor path. `top/` stays, so a `--force` rebuild after the cleanup keeps every sample's rows,
    /// and a symbolic link to a sample folder is neither read nor cleaned.
    func testAForceRebuildAfterTheExecutorsCleanupKeepsEverySamplesRows() async throws {
        let batch = root.appendingPathComponent("taxtriage-batch-2", isDirectory: true)
        try makeODR(at: batch.appendingPathComponent("A", isDirectory: true))
        try makeMini(at: batch.appendingPathComponent("B", isDirectory: true), topOnly: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try makeMini(at: outside)
        try FileManager.default.createSymbolicLink(at: batch.appendingPathComponent("C"), withDestinationURL: outside)

        let index = try await index(batch, layout: .batchRoot)

        XCTAssertEqual(try rowSamples(in: batch), ["SRR12486983", "SRR35517702"])
        XCTAssertTrue(exists("B/top/SRR35517702.top_report.tsv", in: batch))
        for relative in Self.removedSeed {
            XCTAssertFalse(exists("B/\(relative)", in: batch), relative)
            XCTAssertTrue(exists(relative, in: outside), "the linked folder keeps \(relative)")
        }
        let removed = try XCTUnwrap(index.steps.last).inputs.map(\.path)
        XCTAssertTrue(removed.allSatisfy { relative($0, to: batch)?.hasPrefix("B/") == true }, "\(removed)")

        try await buildDb(batch, ["--force", "--no-cleanup", "-q"])
        XCTAssertEqual(try rowSamples(in: batch), ["SRR12486983", "SRR35517702"], "B keeps its rows")
    }
}
