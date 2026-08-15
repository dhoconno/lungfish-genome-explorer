// ClassificationBatchOutcomeTests.swift - Batch classification outcome and summary contracts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class ClassificationBatchOutcomeTests: XCTestCase {
    private let summaryHeader = "sample_id\tstatus\tprofile_state\trequested_rank\tresolved_rank\ttotal_reads\tclassified_reads\tclassified_pct\tspecies_count\tdominant_species\tmessage"

    func testSchemaVersionTwoManifestRoundTripsOutcomeMetadata() throws {
        let batchDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: batchDirectory) }

        let record = MetagenomicsBatchSampleRecord(
            sampleId: "air-B",
            resultDirectory: "air-B",
            inputFiles: ["/data/air-B.fastq.gz"],
            isPairedEnd: false,
            status: "degraded",
            message: "Bracken distribution is unavailable"
        )
        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: Date(timeIntervalSince1970: 1_786_809_600),
                sampleCount: 3
            ),
            goal: "profile",
            databaseName: "SILVA",
            databaseVersion: "2026-08",
            summaryTSV: "classification-batch-summary.tsv",
            samples: [record],
            completedCount: 1,
            degradedCount: 1,
            failedCount: 1
        )

        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchDirectory)
        let loaded = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchDirectory))

        XCTAssertEqual(loaded.header.schemaVersion, 2)
        XCTAssertEqual(loaded.completedCount, 1)
        XCTAssertEqual(loaded.degradedCount, 1)
        XCTAssertEqual(loaded.failedCount, 1)
        XCTAssertEqual(loaded.samples.first?.status, "degraded")
        XCTAssertEqual(loaded.samples.first?.message, "Bracken distribution is unavailable")
    }

    func testLegacySchemaVersionOneManifestDecodesWithNilOutcomeMetadata() throws {
        let batchDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: batchDirectory) }

        let json = #"""
        {
          "header" : {
            "createdAt" : "2026-08-15T12:00:00Z",
            "sampleCount" : 1,
            "schemaVersion" : 1
          },
          "goal" : "profile",
          "databaseName" : "Legacy SILVA",
          "databaseVersion" : "2025-01",
          "summaryTSV" : "classification-batch-summary.tsv",
          "samples" : [
            {
              "inputFiles" : ["/data/legacy.fastq.gz"],
              "isPairedEnd" : false,
              "resultDirectory" : "legacy",
              "sampleId" : "legacy"
            }
          ]
        }
        """#
        let manifestURL = batchDirectory.appendingPathComponent(ClassificationBatchResultManifest.filename)
        try Data(json.utf8).write(to: manifestURL)

        let loaded = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchDirectory))

        XCTAssertEqual(loaded.header.schemaVersion, 1)
        XCTAssertNil(loaded.completedCount)
        XCTAssertNil(loaded.degradedCount)
        XCTAssertNil(loaded.failedCount)
        XCTAssertNil(loaded.samples.first?.status)
        XCTAssertNil(loaded.samples.first?.message)
    }

    func testSummaryRowsDistinguishCompletedDegradedAndFailedSamples() throws {
        let completed = try makeResult(
            kreport: """
            10.00\t10\t10\tU\t0\tunclassified
            90.00\t90\t0\tR\t1\troot
            90.00\t90\t20\tD\t2\t  Bacteria
            70.00\t70\t70\tS\t562\t    Escherichia coli
            """,
            outcome: .completed(resolution: genusResolution)
        )
        let degraded = try makeResult(
            kreport: """
            25.00\t50\t50\tU\t0\tunclassified
            75.00\t150\t0\tR\t1\troot
            75.00\t150\t50\tD\t2759\t  Eukaryota
            50.00\t100\t100\tS\t9544\t    Macaca mulatta
            """,
            outcome: .degraded(
                resolution: genusResolution,
                reason: .distributionUnavailable,
                message: "Missing database100mers.kmer_distrib"
            )
        )

        let rows = [
            ClassificationBatchOutcomePolicy.row(sampleId: "air-A", result: completed),
            ClassificationBatchOutcomePolicy.row(sampleId: "air-B", result: degraded),
            ClassificationBatchOutcomePolicy.failedRow(
                sampleId: "air-C",
                message: "kraken2 exited 2"
            ),
        ]

        XCTAssertEqual(rows.map(\.status), ["ok", "degraded", "failed"])
        XCTAssertEqual(rows.map(\.profileState), ["completed", "degraded", ""])
        XCTAssertEqual(rows.map(\.requestedRank), ["automatic", "automatic", ""])
        XCTAssertEqual(rows.map(\.resolvedRank), ["G", "G", ""])

        let expected = [
            summaryHeader,
            "air-A\tok\tcompleted\tautomatic\tG\t100\t90\t90.00\t1\tEscherichia coli\t",
            "air-B\tdegraded\tdegraded\tautomatic\tG\t200\t150\t75.00\t1\tMacaca mulatta\tMissing database100mers.kmer_distrib",
            "air-C\tfailed\t\t\t\t\t\t\t\t\tkraken2 exited 2",
        ].joined(separator: "\n")
        XCTAssertEqual(ClassificationBatchOutcomePolicy.summaryTSV(rows: rows), expected)

        let evaluation = ClassificationBatchOutcomePolicy.evaluate(rows: rows, sqliteWarning: nil)
        XCTAssertEqual(evaluation.completedCount, 1)
        XCTAssertEqual(evaluation.degradedCount, 1)
        XCTAssertEqual(evaluation.failedCount, 1)
        XCTAssertTrue(evaluation.requiresWarningCompletion)
    }

    func testAnyDegradedOrFailedSampleRequiresWarningCompletion() throws {
        let completed = ClassificationBatchOutcomePolicy.row(
            sampleId: "air-A",
            result: try makeResult(
                kreport: minimalKreport,
                outcome: .completed(resolution: genusResolution)
            )
        )
        let degraded = ClassificationBatchOutcomePolicy.row(
            sampleId: "air-B",
            result: try makeResult(
                kreport: minimalKreport,
                outcome: .degraded(
                    resolution: genusResolution,
                    reason: .rankAbsentFromReport,
                    message: "The requested genus rank was absent from the Kraken report"
                )
            )
        )
        let failed = ClassificationBatchOutcomePolicy.failedRow(
            sampleId: "air-C",
            message: "kraken2 failed"
        )

        XCTAssertFalse(
            ClassificationBatchOutcomePolicy.evaluate(rows: [completed], sqliteWarning: nil)
                .requiresWarningCompletion
        )
        XCTAssertTrue(
            ClassificationBatchOutcomePolicy.evaluate(rows: [degraded], sqliteWarning: nil)
                .requiresWarningCompletion
        )
        XCTAssertTrue(
            ClassificationBatchOutcomePolicy.evaluate(rows: [failed], sqliteWarning: nil)
                .requiresWarningCompletion
        )
    }

    func testSQLiteBuildWarningRequiresWarningCompletionForOtherwiseCompletedBatch() throws {
        let completed = ClassificationBatchOutcomePolicy.row(
            sampleId: "air-A",
            result: try makeResult(
                kreport: minimalKreport,
                outcome: .completed(resolution: genusResolution)
            )
        )

        let evaluation = ClassificationBatchOutcomePolicy.evaluate(
            rows: [completed],
            sqliteWarning: "Unable to build kraken2.sqlite"
        )

        XCTAssertEqual(evaluation.completedCount, 1)
        XCTAssertEqual(evaluation.degradedCount, 0)
        XCTAssertEqual(evaluation.failedCount, 0)
        XCTAssertTrue(evaluation.requiresWarningCompletion)
        XCTAssertTrue(evaluation.warningMessage.contains("Unable to build kraken2.sqlite"))
    }

    func testSingleDegradedResultQualifiesOperationAndAnalysisMetadata() throws {
        let result = try makeResult(
            kreport: minimalKreport,
            outcome: .degraded(
                resolution: genusResolution,
                reason: .distributionUnavailable,
                message: "Missing database100mers.kmer_distrib"
            )
        )

        let metadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: result)

        XCTAssertTrue(metadata.requiresWarningCompletion)
        XCTAssertTrue(metadata.completionDetail.contains("Bracken profiling degraded"))
        XCTAssertTrue(
            metadata.completionDetail.contains("resolved rank G"),
            "Degraded completion detail must identify the resolved Bracken rank"
        )
        XCTAssertTrue(metadata.completionDetail.contains("Missing database100mers.kmer_distrib"))
        XCTAssertTrue(metadata.analysisSummary.contains("profiling degraded"))
        XCTAssertEqual(metadata.analysisParameters["profileState"]?.stringValue, "degraded")
        XCTAssertEqual(metadata.analysisParameters["brackenResolvedRank"]?.stringValue, "G")
        XCTAssertEqual(
            metadata.analysisParameters["brackenDegradationReason"]?.stringValue,
            BrackenProfileDegradationReason.distributionUnavailable.rawValue
        )
    }

    func testAllFailedRetainedBatchReloadsSidebarAfterTerminalFailure() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate+Classification.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let batchFunctionStart = try XCTUnwrap(
            source.range(of: "private func runClassificationBatch(")
        )
        let allFailedStart = try XCTUnwrap(
            source.range(
                of: "if successCount == 0 {",
                range: batchFunctionStart.lowerBound..<source.endIndex
            )
        )
        let followingSuccessPath = try XCTUnwrap(
            source.range(
                of: "if let dbError = capturedDBBuildError {",
                range: allFailedStart.upperBound..<source.endIndex
            )
        )
        let allFailedBranch = String(
            source[allFailedStart.lowerBound..<followingSuccessPath.lowerBound]
        )

        let terminalFailure = try XCTUnwrap(
            allFailedBranch.range(of: "OperationCenter.shared.fail(id: opID")
        )
        let sidebarReload = try XCTUnwrap(
            allFailedBranch.range(of: ".sidebarController.requestReloadFromFilesystem()")
        )
        XCTAssertLessThan(
            terminalFailure.lowerBound,
            sidebarReload.lowerBound,
            "The retained all-failed batch must become visible after its terminal failure is recorded"
        )
        XCTAssertFalse(
            allFailedBranch.contains("removeOwnedBatchRoot"),
            "All-failed scientific evidence must remain available for diagnosis"
        )
    }

    private var genusResolution: BrackenProfileResolution {
        BrackenDatabaseCapabilities.resolve(
            catalogID: "kraken2-special-silva",
            installationRecipe: .kraken2Special(type: .silva),
            request: .automaticDefault
        )
    }

    private var minimalKreport: String {
        """
        10.00\t10\t10\tU\t0\tunclassified
        90.00\t90\t0\tR\t1\troot
        90.00\t90\t20\tD\t2\t  Bacteria
        70.00\t70\t70\tS\t562\t    Escherichia coli
        """
    }

    private func makeResult(
        kreport: String,
        outcome: BrackenProfileOutcome
    ) throws -> ClassificationResult {
        let tree = try KreportParser.parse(text: kreport)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-outcome-fixture-\(UUID().uuidString)", isDirectory: true)
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [directory.appendingPathComponent("reads.fastq.gz")],
            isPairedEnd: false,
            databaseName: "SILVA",
            databaseVersion: "2026-08",
            databasePath: directory.appendingPathComponent("silva-db", isDirectory: true),
            databaseDigest: "sha256:fixture",
            databaseCatalogID: "kraken2-special-silva",
            databaseInstallationRecipe: .kraken2Special(type: .silva),
            brackenProfileRequest: .automaticDefault,
            outputDirectory: directory
        )
        return ClassificationResult(
            config: config,
            tree: tree,
            reportURL: directory.appendingPathComponent("classification.kreport"),
            outputURL: directory.appendingPathComponent("classification.kraken"),
            brackenURL: outcome.state == .completed
                ? directory.appendingPathComponent("classification.bracken")
                : nil,
            profileOutcome: outcome,
            runtime: 1.25,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-batch-outcome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
