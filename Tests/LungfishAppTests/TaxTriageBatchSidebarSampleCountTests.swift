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
