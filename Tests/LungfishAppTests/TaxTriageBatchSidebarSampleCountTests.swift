// TaxTriageBatchSidebarSampleCountTests.swift - The sample count of a TaxTriage batch row in the sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 U30 walk, finding W1. A one-sample TaxTriage run writes the nf-core process folders flat into
// `taxtriage-batch-<ts>/`, on the CLI route (`TaxTriageAnalysisRunTool`, layout `sharedBatchRoot`) and on the
// legacy route alike (whose serial batch runner ran one sample straight into the batch root). The sidebar
// counted the subfolders, so the walk's one-sample run read `12 samples`. The count now comes from the run's
// `taxtriage-result.json` at the batch root, the record the result viewer reads its samples from.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishWorkflow
@testable import LungfishTaxonomyUI

final class TaxTriageBatchSidebarSampleCountTests: XCTestCase {
    private var tempRoot: URL!
    private var projectURL: URL!

    /// The twelve process folders the walk's one-sample CLI run left in its batch root.
    private static let processFolders = [
        "alignment", "combine", "fastp", "fastqc", "kraken2", "kreport", "minimap2", "pigz",
        "pipeline_info", "removetaxidsclassification", "report", "top",
    ]

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageBatchSidebarSampleCount-\(UUID().uuidString)", isDirectory: true)
        tempRoot = root
        projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    /// A one-sample run's flat batch root reads `1 samples`, not one sample per process folder.
    func testOneSampleRunWithFlatProcessFoldersCountsOneSample() throws {
        let batch = try makeBatch(sampleIDs: ["SRR12486983"], subfolders: Self.processFolders)
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: batch))

        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("1 samples · "), "the walk's one-sample run read \(subtitle)")
        let node = try XCTUnwrap(SidebarProjectScanner.buildAnalysisNode(info: info))
        XCTAssertEqual(node.subtitle, subtitle)
    }

    /// A run of several samples, one folder each, still reads its sample count.
    func testSeveralSampleRunWithSampleFoldersCountsItsSamples() throws {
        let batch = try makeBatch(sampleIDs: ["SRR12486983", "SRR12486989"], subfolders: ["SRR12486983", "SRR12486989"])
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: batch))

        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("2 samples · "), subtitle)
    }

    /// A batch root with no run record keeps today's count of its sample folders.
    func testBatchWithoutRunRecordCountsSampleFolders() throws {
        let batch = try makeBatch(sampleIDs: [], subfolders: ["S1", "S2", "S3"])
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: batch))

        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("3 samples · "), subtitle)
    }

    /// A run record that cannot be decoded counts the sample folders, as a batch with no record does.
    func testUnreadableRunRecordCountsSampleFolders() throws {
        let batch = try makeBatch(sampleIDs: [], subfolders: ["S1", "S2"])
        try Data("{".utf8).write(to: batch.appendingPathComponent("taxtriage-result.json"))
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: batch))

        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("2 samples · "), subtitle)
    }

    // MARK: - Imported results (Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN)

    /// A one-sample run made inside a project carries `isBatch` true. Its import has a row in the sidebar.
    func testImportedOneSampleBatchIsListed() throws {
        let imported = try importRun(sampleIDs: ["SRR12486983"])
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: imported))

        XCTAssertNotNil(SidebarProjectScanner.buildAnalysisNode(info: info), "the imported one-sample run has no sidebar row")
    }

    /// A two-sample run keeps its record through the import, so the row reads two samples.
    func testImportedTwoSampleBatchReadsTwoSamples() throws {
        let imported = try importRun(sampleIDs: ["S1", "S2"])
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: imported))

        XCTAssertNotNil(SidebarProjectScanner.buildAnalysisNode(info: info), "the imported two-sample run has no sidebar row")
        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("2 samples · "), subtitle)
    }

    /// An import from an earlier release holds a record with no samples and reports. It is listed, and says why it has no count.
    func testOlderImportWithEmptySamplesAndReportsIsListed() throws {
        let older = try makeOlderImport(reportCount: 1)
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: older))

        XCTAssertNotNil(SidebarProjectScanner.buildAnalysisNode(info: info), "the older import has no sidebar row")
        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("Samples not recorded · "), subtitle)
    }

    /// An older import with no samples and no reports is listed too, and says it has no reports.
    func testOlderImportWithNoReportsIsListed() throws {
        let older = try makeOlderImport(reportCount: 0)
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: older))

        XCTAssertNotNil(SidebarProjectScanner.buildAnalysisNode(info: info), "the older import has no sidebar row")
        let subtitle = try XCTUnwrap(SidebarProjectScanner.classifierBatchSubtitle(for: info))
        XCTAssertTrue(subtitle.hasPrefix("No reports · "), subtitle)
    }

    /// Listing an older import is a read. No file of its folder is added or changed (UX 6).
    func testListingAnOlderImportWritesNothing() throws {
        let older = try makeOlderImport(reportCount: 1)
        let before = try folderSnapshot(of: older)
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: older))

        XCTAssertNotNil(SidebarProjectScanner.buildAnalysisNode(info: info), "the older import has no sidebar row")
        _ = SidebarProjectScanner.classifierBatchSubtitle(for: info)
        XCTAssertEqual(try folderSnapshot(of: older), before, "listing changed the older import's folder")
    }

    /// What an earlier release imported: a batch-marked folder whose record names no samples and `reportCount` reports.
    private func makeOlderImport(reportCount: Int) throws -> URL {
        let batch = try makeBatch(sampleIDs: [], subfolders: [])
        var reports: [URL] = []
        for index in 0..<reportCount {
            let report = batch.appendingPathComponent("S\(index).top_report.tsv")
            try "taxid\tname\treads\n111\tVirus A\t12\n".write(to: report, atomically: true, encoding: .utf8)
            reports.append(report)
        }
        let config = TaxTriageConfig(samples: [], outputDirectory: batch)
        try TaxTriageResult(config: config, runtime: 0, exitCode: 0, outputDirectory: batch, reportFiles: reports).save()
        return batch
    }

    /// Every regular file under `folder` with its bytes, by path relative to the folder.
    private func folderSnapshot(of folder: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            snapshot[String(file.path.dropFirst(folder.path.count))] = try Data(contentsOf: file)
        }
        return snapshot
    }

    /// A run folder as `taxtriage run` leaves it in a project (`isBatch` true, one folder and one report a sample, the run's
    /// own record), imported into the project's `Analyses` folder with the real importer. Returns the imported folder.
    private func importRun(sampleIDs: [String]) throws -> URL {
        let source = tempRoot.appendingPathComponent("run-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true), to: source)
        var reports: [URL] = []
        for id in sampleIDs {
            let folder = source.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report = folder.appendingPathComponent("\(id).top_report.tsv")
            try "taxid\tname\treads\n111\tVirus A\t12\n".write(to: report, atomically: true, encoding: .utf8)
            reports.append(report)
        }
        let config = TaxTriageConfig(
            samples: sampleIDs.map { TaxTriageSample(sampleId: $0, fastq1: tempRoot.appendingPathComponent("\($0).fastq.gz")) },
            outputDirectory: source,
            maxCpus: 2,
            profile: "docker"
        )
        try TaxTriageResult(config: config, runtime: 417, exitCode: 0, outputDirectory: source, reportFiles: reports).save()
        return try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: projectURL.appendingPathComponent("Analyses", isDirectory: true)
        ).resultDirectory
    }

    /// A `taxtriage-batch-<ts>` folder in the project with `subfolders`, and with the run's
    /// `taxtriage-result.json` naming `sampleIDs` unless that list is empty.
    private func makeBatch(sampleIDs: [String], subfolders: [String]) throws -> URL {
        let batch = try AnalysesFolder.createAnalysisDirectory(
            tool: "taxtriage",
            in: projectURL,
            isBatch: true,
            date: Date(timeIntervalSince1970: 1_760_000_000)
        )
        for name in subfolders {
            try FileManager.default.createDirectory(
                at: batch.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        guard !sampleIDs.isEmpty else { return batch }
        let config = TaxTriageConfig(
            samples: sampleIDs.map {
                TaxTriageSample(sampleId: $0, fastq1: tempRoot.appendingPathComponent("\($0).fastq.gz"))
            },
            outputDirectory: batch,
            kraken2DatabasePath: tempRoot.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2,
            profile: "docker"
        )
        try TaxTriageResult(config: config, runtime: 417, exitCode: 0, outputDirectory: batch).save()
        return batch
    }
}
