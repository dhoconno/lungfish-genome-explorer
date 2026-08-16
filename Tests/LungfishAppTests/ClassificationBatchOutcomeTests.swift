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

    func testSingleClassificationFailureRetainsOwnedAnalysisEvidence() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate+Classification.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let functionStart = try XCTUnwrap(
            source.range(of: "internal func runClassification(\n        config:")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "/// Runs the EsViritu viral detection pipeline.",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let functionBody = String(source[functionStart.lowerBound..<functionEnd.lowerBound])
        let catchStart = try XCTUnwrap(functionBody.range(of: "            } catch {"))
        let catchBody = String(functionBody[catchStart.lowerBound...])

        XCTAssertFalse(
            catchBody.contains("removeItem(at: config.outputDirectory)"),
            "A hard failure or cancellation must retain the pipeline provenance written to the owned analysis directory"
        )
    }

    func testClassificationBatchCancellationPersistsEvidenceBeforeTerminalFailure() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate+Classification.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let functionStart = try XCTUnwrap(
            source.range(of: "private func runClassificationBatch(")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "/// Runs EsViritu detection in batch mode",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let functionBody = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        XCTAssertFalse(
            functionBody.contains("removeOwnedBatchRoot"),
            "Cancellation must retain partial child and root provenance"
        )
        let provenanceWrite = try XCTUnwrap(
            functionBody.range(of: "MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance")
        )
        let terminalCancellation = try XCTUnwrap(
            functionBody.range(
                of: "if batchWasCancelled {",
                range: provenanceWrite.upperBound..<functionBody.endIndex
            )
        )
        XCTAssertLessThan(
            provenanceWrite.lowerBound,
            terminalCancellation.lowerBound,
            "The root envelope must be persisted before the cancelled operation returns"
        )
    }

    func testBatchSetupFailurePersistsSummaryManifestAndRootProvenance() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputA = root.appendingPathComponent("air-A.fastq")
        let inputB = root.appendingPathComponent("air-B.fastq")
        try "@a\nAC\n+\nII\n".write(to: inputA, atomically: true, encoding: .utf8)
        try "@b\nGT\n+\nII\n".write(to: inputB, atomically: true, encoding: .utf8)
        let batchRoot = root.appendingPathComponent("classification-batch", isDirectory: true)
        let databasePath = root.appendingPathComponent("database", isDirectory: true)
        try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)
        let configs = [
            makeConfig(input: inputA, output: batchRoot.appendingPathComponent("air-A"), databasePath: databasePath),
            makeConfig(input: inputB, output: batchRoot.appendingPathComponent("air-B"), databasePath: databasePath),
        ]
        let command = ["/bin/sh", "-c", "replay air-A\nreplay air-B"]
        let startedAt = Date(timeIntervalSince1970: 1_786_809_600)

        let provenanceURL = try AppDelegate.persistClassificationBatchSetupFailure(
            batchRoot: batchRoot,
            configurations: configs,
            sampleIDs: ["air-A", "air-B"],
            command: command,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(2.5),
            errorDescription: "Unable to create materialization directory"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        let summary = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertTrue(summary.contains("air-A\tfailed"))
        XCTAssertTrue(summary.contains("air-B\tfailed"))
        XCTAssertTrue(summary.contains("Unable to create materialization directory"))
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        XCTAssertEqual(manifest.header.sampleCount, 2)
        XCTAssertEqual(manifest.failedCount, 2)
        XCTAssertEqual(manifest.completedCount, 0)
        XCTAssertEqual(manifest.degradedCount, 0)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        XCTAssertEqual(envelope.argv, command)
        XCTAssertNotEqual(envelope.exitStatus, 0)
        XCTAssertEqual(try XCTUnwrap(envelope.wallTimeSeconds), 2.5, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(envelope.stderr).contains("Unable to create materialization directory"))
        XCTAssertTrue(envelope.files.contains { $0.path == inputA.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(envelope.files.contains { $0.path == inputB.path && $0.checksumSHA256 != nil })
    }

    func testBatchSetupArtifactWriteFailureFallsBackToRootProvenance() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("air-A.fastq")
        try "@a\nAC\n+\nII\n".write(to: input, atomically: true, encoding: .utf8)
        let batchRoot = root.appendingPathComponent("classification-batch", isDirectory: true)
        let databasePath = root.appendingPathComponent("database", isDirectory: true)
        try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        try FileManager.default.createDirectory(at: summaryURL, withIntermediateDirectories: true)
        let config = makeConfig(
            input: input,
            output: batchRoot.appendingPathComponent("air-A"),
            databasePath: databasePath
        )
        let command = ["/bin/sh", "-c", "replay air-A"]
        let startedAt = Date(timeIntervalSince1970: 1_786_809_600)

        let provenanceURL = try AppDelegate.persistClassificationBatchSetupFailure(
            batchRoot: batchRoot,
            configurations: [config],
            sampleIDs: ["air-A"],
            command: command,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(3.25),
            errorDescription: "Unable to create materialization directory"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        XCTAssertNil(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        XCTAssertEqual(envelope.argv, command)
        XCTAssertEqual(envelope.durableReplayArgv, command)
        XCTAssertNotEqual(envelope.exitStatus, 0)
        XCTAssertEqual(try XCTUnwrap(envelope.wallTimeSeconds), 3.25, accuracy: 0.001)
        let stderr = try XCTUnwrap(envelope.stderr)
        XCTAssertTrue(stderr.contains("Unable to create materialization directory"))
        XCTAssertTrue(stderr.contains("classification-batch-summary.tsv"))
        XCTAssertTrue(envelope.files.contains { $0.path == input.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.explicit["databasePath"]?.stringValue, databasePath.path)
        XCTAssertEqual(envelope.options.explicit["databaseDigest"]?.stringValue, config.databaseDigest)
    }

    func testNormalBatchArtifactWriteFailureAttemptsRootProvenanceBeforeReturning() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate+Classification.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let detail = try XCTUnwrap(
            source.range(of: "Failed to write classification batch artifacts:")
        )
        let terminalReturn = try XCTUnwrap(
            source.range(of: "                return", range: detail.upperBound..<source.endIndex)
        )
        let catchBody = String(source[detail.lowerBound..<terminalReturn.upperBound])

        XCTAssertTrue(
            catchBody.contains("persistClassificationBatchFailureRoot"),
            "A summary or manifest write failure after scientific work must still attempt a root failure envelope"
        )
    }

    func testNormalBatchRootProvenanceWriteFailureAttemptsIndependentFailureRoot() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate+Classification.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let detail = try XCTUnwrap(
            source.range(of: "Failed to write classification batch provenance:")
        )
        let terminalReturn = try XCTUnwrap(
            source.range(of: "                return", range: detail.upperBound..<source.endIndex)
        )
        let catchBody = String(source[detail.lowerBound..<terminalReturn.upperBound])

        XCTAssertTrue(
            catchBody.contains("persistClassificationBatchFailureRoot"),
            "A standard root provenance publication failure must attempt the independent failure-root writer"
        )
        XCTAssertTrue(catchBody.contains("batch-provenance-publication"))
    }

    func testBatchReplayCommandCapturesEachResolvedSampleConfiguration() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputA = root.appendingPathComponent("air A.fastq")
        let inputB = root.appendingPathComponent("air-B.fastq")
        let databasePath = root.appendingPathComponent("silva db", isDirectory: true)
        var automatic = makeConfig(
            input: inputA,
            output: root.appendingPathComponent("result A", isDirectory: true),
            databasePath: databasePath
        )
        automatic.confidence = 0.2
        automatic.minimumHitGroups = 3
        automatic.threads = 7
        automatic.memoryMapping = true
        automatic.quickMode = true
        automatic.extraArguments = ["--minimum-base-quality", "20"]
        var explicit = ClassificationConfig(
            goal: .profile,
            inputFiles: [inputB],
            isPairedEnd: false,
            databaseName: "SILVA",
            databaseVersion: "2026-08",
            databasePath: databasePath,
            databaseDigest: "sha256:fixture",
            databaseCatalogID: "kraken2-special-silva",
            databaseInstallationRecipe: .kraken2Special(type: .silva),
            brackenProfileRequest: BrackenProfileRequest(
                rank: .explicit(.genus),
                readLength: 150,
                threshold: 25
            ),
            outputDirectory: root.appendingPathComponent("result-B", isDirectory: true)
        )
        explicit.originalInputFiles = [inputB]

        let command: [String] = AppDelegate.classificationBatchReplayCommand(
            configurations: [automatic, explicit]
        )

        XCTAssertEqual(command.prefix(2), ["/bin/sh", "-c"])
        let script = try XCTUnwrap(command.last)
        XCTAssertTrue(script.hasPrefix("set -e\n"))
        XCTAssertEqual(script.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(script.contains("conda classify"))
        XCTAssertTrue(script.contains("--output-dir"))
        XCTAssertTrue(script.contains(shellEscape(automatic.outputDirectory.path)))
        XCTAssertTrue(script.contains(shellEscape(explicit.outputDirectory.path)))
        XCTAssertTrue(script.contains("--profile"))
        XCTAssertTrue(script.contains("--bracken-read-length 150"))
        XCTAssertTrue(script.contains("--bracken-threshold 10"))
        XCTAssertTrue(script.contains("--bracken-threshold 25"))
        XCTAssertTrue(script.contains("--bracken-level G"))
        XCTAssertTrue(script.contains("--confidence 0.2"))
        XCTAssertTrue(script.contains("--min-hit-groups 3"))
        XCTAssertTrue(script.contains("--threads 7"))
        XCTAssertTrue(script.contains("--memory-mapping"))
        XCTAssertTrue(script.contains("--quick"))
        XCTAssertTrue(script.contains(shellEscape(inputA.path)))
        XCTAssertTrue(script.contains(shellEscape(inputB.path)))
        XCTAssertTrue(script.contains(shellEscape(databasePath.standardizedFileURL.path)))
        XCTAssertTrue(script.contains(shellEscape(automatic.databaseDigest ?? "")))
        XCTAssertTrue(script.contains(ProvenanceWriter.provenanceFilename))
        XCTAssertTrue(script.contains("conda db info"))
        let databaseGuard = try XCTUnwrap(
            script.range(of: shellEscape(databasePath.standardizedFileURL.path))
        )
        let firstClassification = try XCTUnwrap(script.range(of: "lungfish-cli conda classify"))
        XCTAssertLessThan(
            databaseGuard.lowerBound,
            firstClassification.lowerBound,
            "Replay must verify the immutable database identity before invoking classification"
        )
        XCTAssertFalse(script.contains("classification-batch --output"))
    }

    func testBatchReplayStopsBeforeAnyClassificationWhenDatabaseIdentityGuardFails() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingDatabase = root.appendingPathComponent("missing-database", isDirectory: true)
        let validDatabase = root.appendingPathComponent("valid database", isDirectory: true)
        try FileManager.default.createDirectory(at: validDatabase, withIntermediateDirectories: true)
        let digest = "sha256:fixture"
        let receipt = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_786_809_600),
            workflowName: "Fixture database install",
            toolName: "fixture-installer",
            argv: ["fixture-installer"],
            options: ProvenanceOptions(
                resolvedDefaults: [
                    "payloadAggregateSHA256": .string(digest),
                    "intendedFinalPath": .string(validDatabase.standardizedFileURL.path),
                ]
            ),
            exitStatus: 0
        )
        _ = try ProvenanceWriter().write(receipt, to: validDatabase)

        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("classification-ran")
        let fakeCLI = fakeBin.appendingPathComponent("lungfish-cli")
        let fakeScript = """
        #!/bin/sh
        if [ "$1 $2 $3" = "conda db info" ]; then
          /usr/bin/printf 'Location: %s\\n' "$FAKE_DATABASE_PATH"
          exit 0
        fi
        /usr/bin/touch "$CLASSIFICATION_MARKER"
        exit 0
        """
        try fakeScript.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeCLI.path
        )

        let first = makeConfig(
            input: root.appendingPathComponent("air-A.fastq"),
            output: root.appendingPathComponent("result-A"),
            databasePath: missingDatabase
        )
        let second = makeConfig(
            input: root.appendingPathComponent("air-B.fastq"),
            output: root.appendingPathComponent("result-B"),
            databasePath: validDatabase
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBin.path + ":" + (environment["PATH"] ?? "")
        environment["FAKE_DATABASE_PATH"] = validDatabase.standardizedFileURL.path
        environment["CLASSIFICATION_MARKER"] = marker.path
        func runReplay(_ configurations: [ClassificationConfig]) throws -> Int32 {
            let command = AppDelegate.classificationBatchReplayCommand(
                configurations: configurations
            )
            let script = try XCTUnwrap(command.last)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertEqual(try runReplay([second]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: marker)

        environment["FAKE_DATABASE_PATH"] = validDatabase.standardizedFileURL.path + "-old"
        XCTAssertNotEqual(try runReplay([second]), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "A registry location that merely contains the captured path must fail closed"
        )
        try? FileManager.default.removeItem(at: marker)
        environment["FAKE_DATABASE_PATH"] = validDatabase.standardizedFileURL.path

        XCTAssertNotEqual(try runReplay([first, second]), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "A failed immutable database guard must terminate the whole batch replay"
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

    private func makeConfig(input: URL, output: URL, databasePath: URL) -> ClassificationConfig {
        ClassificationConfig(
            goal: .profile,
            inputFiles: [input],
            isPairedEnd: false,
            databaseName: "SILVA",
            databaseVersion: "2026-08",
            databasePath: databasePath,
            databaseDigest: "sha256:fixture",
            databaseCatalogID: "kraken2-special-silva",
            databaseInstallationRecipe: .kraken2Special(type: .silva),
            brackenProfileRequest: .automaticDefault,
            outputDirectory: output
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-batch-outcome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
