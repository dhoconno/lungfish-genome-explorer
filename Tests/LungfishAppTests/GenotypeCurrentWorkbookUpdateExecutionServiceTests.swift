import XCTest
import Darwin
import LungfishIO
import LungfishWorkflow
import LungfishKit
@testable import LungfishApp

@MainActor
final class GenotypeCurrentWorkbookUpdateExecutionServiceTests: XCTestCase {
    func testRunInvokesCLIAndRecordsOperationMetadata() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent("amplicon-genotyping.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("artifacts/workbooks/updates", isDirectory: true),
            withIntermediateDirectories: true
        )
        let annotationURL = bundleURL.appendingPathComponent("annotations.json")
        try annotationData(editor: "metadata-test").write(to: annotationURL)
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let calls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "LF2888",
                locus: "MHC-DP",
                haplotype1: "M1DP",
                haplotype2: "M4DP",
                status: "called",
                notes: "manual review"
            ),
        ]
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: try successPayloadJSON(for: bundleURL),
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: "b", count: 64),
            reviewableRowCatalogPath:
                "artifacts/review/reviewable-row-catalog.json",
            reviewableRowCatalogSize: 123,
            reviewableRowCatalogSHA256: String(repeating: "c", count: 64),
            reviewableRowCatalogSchemaVersion: 1
        )

        try await service.run(
            bundleURL: bundleURL,
            calls: calls,
            includedLoci: ["MHC-A", "MHC-DP"],
            annotationSidecarURL: annotationURL,
            haplotypeProjectionMode: .manualGenotypeOnly,
            inputFingerprint: fingerprint,
            syncIntent: .updateAndView
        )

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.workingDirectory, bundleURL.standardizedFileURL)
        XCTAssertEqual(invocation.arguments.prefix(2), ["fastq", "update-current-workbook"])
        XCTAssertEqual(invocation.arguments[2], bundleURL.standardizedFileURL.path)
        let callsURL = URL(fileURLWithPath: try value(after: "--calls-json", in: invocation.arguments))
        XCTAssertTrue(FileManager.default.fileExists(atPath: callsURL.path))
        let decoded = try JSONDecoder().decode(
            [GenotypeWorkbookHaplotypeCall].self,
            from: Data(contentsOf: callsURL)
        )
        XCTAssertEqual(decoded, calls)
        XCTAssertEqual(
            invocation.arguments.filter { $0 == "--included-locus" }.count,
            2
        )
        XCTAssertEqual(try values(after: "--included-locus", in: invocation.arguments), ["MHC-A", "MHC-DP"])
        let retainedAnnotationURL = URL(
            fileURLWithPath: try value(after: "--annotations", in: invocation.arguments)
        )
        XCTAssertNotEqual(
            retainedAnnotationURL.standardizedFileURL,
            annotationURL.standardizedFileURL
        )
        XCTAssertTrue(
            retainedAnnotationURL.standardizedFileURL.path.hasPrefix(
                bundleURL
                    .appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
                    .standardizedFileURL.path + "/"
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedAnnotationURL),
            try Data(contentsOf: annotationURL)
        )
        XCTAssertEqual(invocation.arguments.filter { $0 == "--input-fingerprint" }.count, 1)
        XCTAssertEqual(invocation.arguments.filter { $0 == "--input-fingerprint-schema" }.count, 1)
        XCTAssertEqual(
            try value(after: "--reviewable-row-catalog-path", in: invocation.arguments),
            "artifacts/review/reviewable-row-catalog.json"
        )
        XCTAssertEqual(
            try value(after: "--reviewable-row-catalog-size", in: invocation.arguments),
            "123"
        )
        XCTAssertEqual(
            try value(after: "--reviewable-row-catalog-sha256", in: invocation.arguments),
            String(repeating: "c", count: 64)
        )
        XCTAssertEqual(
            try value(after: "--reviewable-row-catalog-schema", in: invocation.arguments),
            "1"
        )
        XCTAssertEqual(invocation.arguments.filter { $0 == "--sync-intent" }.count, 1)
        XCTAssertEqual(try value(after: "--input-fingerprint", in: invocation.arguments), fingerprint.sha256)
        XCTAssertEqual(
            try value(after: "--input-fingerprint-schema", in: invocation.arguments),
            String(fingerprint.schemaVersion)
        )
        XCTAssertEqual(try value(after: "--sync-intent", in: invocation.arguments), "update-and-view")
        XCTAssertEqual(
            try value(
                after: "--haplotype-projection-mode",
                in: invocation.arguments
            ),
            "manual-genotype-only"
        )

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "Update current.xlsx")
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.targetBundleURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq update-current-workbook") == true)
        XCTAssertTrue(item.cliCommand?.contains("--included-locus MHC-A --included-locus MHC-DP") == true)
        XCTAssertTrue(item.cliCommand?.contains("--input-fingerprint \(fingerprint.sha256)") == true)
        XCTAssertTrue(
            item.cliCommand?.contains(
                "--input-fingerprint-schema \(fingerprint.schemaVersion)"
            ) == true
        )
        XCTAssertTrue(
            item.cliCommand?.contains(
                "--reviewable-row-catalog-path artifacts/review/reviewable-row-catalog.json"
            ) == true
        )
        XCTAssertTrue(item.cliCommand?.contains("--sync-intent update-and-view") == true)
        XCTAssertTrue(
            item.cliCommand?.contains(
                "--haplotype-projection-mode manual-genotype-only"
            ) == true
        )
        XCTAssertTrue(item.cliCommand?.contains(retainedAnnotationURL.path) == true)
        XCTAssertFalse(item.cliCommand?.contains(annotationURL.path) == true)
        XCTAssertTrue(item.outputURLs.contains(bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx").standardizedFileURL))
        XCTAssertTrue(item.logEntries.contains { $0.message == "Updated current.xlsx" })
        XCTAssertTrue(item.logEntries.contains { $0.message == "Included loci: MHC-A, MHC-DP" })
        XCTAssertTrue(item.logEntries.contains {
            $0.message == "Annotations: \(retainedAnnotationURL.path)"
        })
    }

    func testCommittedWorkbookCleanupWarningCompletesOperationAndReturnsWorkbook() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "cleanup-warning.lungfishgenotype",
            isDirectory: true
        )
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let warning = "Workbook updated; retired-generation cleanup pending."
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput:
                "[managed-runtime] ready\n"
                + (try successPayloadJSON(
                    for: bundleURL,
                    cleanupPending: true,
                    warning: warning
                )),
            standardError: "[100%] \(warning)\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        let returnedURL = try await service.run(
            bundleURL: bundleURL,
            calls: [],
            annotationSidecarURL: nil
        )

        let canonicalWorkbook = canonicalWorkbookURL(for: bundleURL)
        XCTAssertEqual(returnedURL, canonicalWorkbook)
        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.detail, "Completed — cleanup pending")
        XCTAssertEqual(item.outputURLs, [canonicalWorkbook])
        XCTAssertTrue(item.logEntries.contains {
            $0.level == .warning && $0.message == warning
        })
    }

    func testBlockingPreflightRecoveryFailureKeepsOperationFailedAndDoesNotOpenWorkbook() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "preflight-failure.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sentence = """
        The existing workbook is valid, but this new update was not applied because a prior retired generation could not be cleaned up safely.
        """
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 1,
            standardOutput: "",
            standardError: sentence
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: nil
            )
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.errorDetail?.contains(sentence) == true)
        XCTAssertTrue(item.outputURLs.isEmpty)
    }

    func testLegacySuccessPayloadWithoutCleanupFieldsRemainsCompatible() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "legacy-payload.lungfishgenotype",
            isDirectory: true
        )
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: try successPayloadJSON(
                for: bundleURL,
                includeCleanupFields: false
            ),
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        let returnedURL = try await service.run(
            bundleURL: bundleURL,
            calls: [],
            annotationSidecarURL: nil
        )

        XCTAssertEqual(returnedURL, canonicalWorkbookURL(for: bundleURL))
        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.detail, "Updated current.xlsx")
    }

    func testMalformedSuccessPayloadFailsOperationWithoutOpeningWorkbook() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "malformed-payload.lungfishgenotype",
            isDirectory: true
        )
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "[managed-runtime] ready\n{\"bundlePath\":",
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: nil
            )
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.outputURLs.isEmpty)
        XCTAssertTrue(item.errorDetail?.contains("payload") == true)
        XCTAssertEqual(
            try retainedInputSnapshots(in: bundleURL).count,
            1,
            "An exit-0 CLI result may already have committed the workbook, so its immutable provenance inputs must remain."
        )
    }

    func testSuccessPayloadMissingHistoricalPathFailsOperationWithoutOpeningWorkbook() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "missing-payload-field.lungfishgenotype",
            isDirectory: true
        )
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let incompletePayload = try JSONSerialization.data(
            withJSONObject: [
                "bundlePath": bundleURL.standardizedFileURL.path,
                "currentWorkbookPath": canonicalWorkbookURL(for: bundleURL).path,
            ],
            options: [.sortedKeys]
        )
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: try XCTUnwrap(
                String(data: incompletePayload, encoding: .utf8)
            ),
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: nil
            )
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.outputURLs.isEmpty)
    }

    func testMismatchedOrEscapingPayloadPathsFailOperationWithoutOpeningWorkbook() async throws {
        enum InvalidPayloadCase: CaseIterable {
            case mismatchedBundle
            case noncanonicalWorkbook
            case outsideManifest
            case symlinkedWorkbook
        }

        for invalidCase in InvalidPayloadCase.allCases {
            let temp = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let bundleURL = temp.appendingPathComponent(
                "\(invalidCase).lungfishgenotype",
                isDirectory: true
            )
            try createCanonicalWorkbookOutputs(in: bundleURL)
            let outsideURL = temp.appendingPathComponent("outside.xlsx")
            try Data("outside".utf8).write(to: outsideURL)

            var bundlePath = bundleURL.standardizedFileURL.path
            var workbookPath = canonicalWorkbookURL(for: bundleURL).path
            var manifestPath = canonicalManifestURL(for: bundleURL).path
            switch invalidCase {
            case .mismatchedBundle:
                bundlePath = temp.appendingPathComponent("other.lungfishgenotype").path
            case .noncanonicalWorkbook:
                workbookPath = bundleURL
                    .appendingPathComponent("artifacts/workbooks/../workbooks/current.xlsx")
                    .path
            case .outsideManifest:
                manifestPath = temp.appendingPathComponent("manifest.json").path
            case .symlinkedWorkbook:
                try FileManager.default.removeItem(at: canonicalWorkbookURL(for: bundleURL))
                try FileManager.default.createSymbolicLink(
                    at: canonicalWorkbookURL(for: bundleURL),
                    withDestinationURL: outsideURL
                )
            }
            let operationCenter = OperationCenter()
            let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
                exitCode: 0,
                standardOutput: try payloadJSON(
                    bundlePath: bundlePath,
                    workbookPath: workbookPath,
                    manifestPath: manifestPath
                ),
                standardError: "[100%] Updated current.xlsx\n"
            ))
            let service = GenotypeCurrentWorkbookUpdateExecutionService(
                operationCenter: operationCenter,
                processRunner: runner
            )

            await XCTAssertThrowsErrorAsync {
                try await service.run(
                    bundleURL: bundleURL,
                    calls: [],
                    annotationSidecarURL: nil
                )
            }

            let item = try XCTUnwrap(operationCenter.items.first)
            XCTAssertEqual(item.state, .failed, "\(invalidCase)")
            XCTAssertTrue(item.outputURLs.isEmpty, "\(invalidCase)")
            XCTAssertEqual(
                try retainedInputSnapshots(in: bundleURL).count,
                1,
                "\(invalidCase)"
            )
        }
    }

    func testFailureReportsCLIExitStatusAndStderr() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent("amplicon-genotyping.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let operationCenter = OperationCenter()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 64,
            standardOutput: "",
            standardError: "ModuleNotFoundError: No module named 'openpyxl'\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )

        do {
            try await service.run(bundleURL: bundleURL, calls: [], annotationSidecarURL: nil)
            XCTFail("Expected workbook update failure")
        } catch LocalWorkflowExecutionError.nonZeroExit(let status) {
            XCTAssertEqual(status, 64)
        }

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, "current.xlsx update failed")
        XCTAssertTrue(item.errorDetail?.contains("exit code 64") == true)
        XCTAssertTrue(item.errorDetail?.contains("No module named 'openpyxl'") == true)
        XCTAssertTrue(item.cliCommand?.contains("fastq update-current-workbook") == true)
    }

    func testAnnotationOnlyUpdatePassesExplicitCLIIntentWithDisplayedCallsSnapshot() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "annotation-only.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("artifacts/workbooks/updates", isDirectory: true),
            withIntermediateDirectories: true
        )
        let annotationURL = bundleURL.appendingPathComponent("annotations.json")
        try annotationData(editor: "annotation-only-test").write(to: annotationURL)
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: try successPayloadJSON(for: bundleURL),
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )
        let displayedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: "displayed snapshot"
            ),
        ]

        try await service.run(
            bundleURL: bundleURL,
            calls: displayedCalls,
            annotationSidecarURL: annotationURL,
            annotationOnly: true
        )

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(invocation.arguments.contains("--annotation-only"))
        XCTAssertFalse(invocation.arguments.contains("--input-fingerprint"))
        XCTAssertFalse(invocation.arguments.contains("--input-fingerprint-schema"))
        XCTAssertFalse(invocation.arguments.contains("--sync-intent"))
        let callsURL = URL(
            fileURLWithPath: try value(after: "--calls-json", in: invocation.arguments)
        )
        let decoded = try JSONDecoder().decode(
            [GenotypeWorkbookHaplotypeCall].self,
            from: Data(contentsOf: callsURL)
        )
        XCTAssertEqual(decoded, displayedCalls)
    }

    func testRunUsesImmutableRetainedAnnotationSnapshotsAcrossSupersedingRequests() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "immutable-annotations.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let liveAnnotationURL = bundleURL.appendingPathComponent("annotations.json")
        let admittedA = try annotationData(editor: "analyst-a")
        let admittedB = try annotationData(editor: "analyst-b")
        try admittedA.write(to: liveAnnotationURL)

        var annotationPayloadsSeenByCLI: [Data] = []
        var annotationURLsSeenByCLI: [URL] = []
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: try successPayloadJSON(for: bundleURL),
            standardError: "[100%] Updated current.xlsx\n"
        )) { invocation in
            let annotationPath = try self.value(
                after: "--annotations",
                in: invocation.arguments
            )
            let annotationURL = URL(fileURLWithPath: annotationPath)
            annotationURLsSeenByCLI.append(annotationURL)
            annotationPayloadsSeenByCLI.append(try Data(contentsOf: annotationURL))
        }
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        // Request A has already captured its immutable sidecar when a later edit
        // reaches the live bundle sidecar.
        try admittedB.write(to: liveAnnotationURL, options: .atomic)
        try await service.run(
            bundleURL: bundleURL,
            calls: [],
            annotationSidecarURL: liveAnnotationURL,
            annotationSidecarData: admittedA
        )
        try await service.run(
            bundleURL: bundleURL,
            calls: [],
            annotationSidecarURL: liveAnnotationURL,
            annotationSidecarData: admittedB
        )

        XCTAssertEqual(annotationPayloadsSeenByCLI, [admittedA, admittedB])
        XCTAssertEqual(Set(annotationURLsSeenByCLI).count, 2)
        let updatesDirectory = bundleURL
            .appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
            .standardizedFileURL
        for annotationURL in annotationURLsSeenByCLI {
            XCTAssertNotEqual(annotationURL.standardizedFileURL, liveAnnotationURL.standardizedFileURL)
            XCTAssertTrue(
                annotationURL.standardizedFileURL.path.hasPrefix(
                    updatesDirectory.path + "/"
                )
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: annotationURL.path))
        }
    }

    func testRunRejectsSymlinkedUpdatesDirectoryWithoutWritingSnapshotOutsideBundle() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "unsafe-updates.lungfishgenotype",
            isDirectory: true
        )
        let workbooksDirectory = bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workbooksDirectory,
            withIntermediateDirectories: true
        )
        let outsideDirectory = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: workbooksDirectory.appendingPathComponent("updates"),
            withDestinationURL: outsideDirectory
        )
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
            standardError: ""
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        do {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: bundleURL.appendingPathComponent("annotations.json"),
                annotationSidecarData: try annotationData(editor: "symlink-test")
            )
            XCTFail("Expected an unsafe updates-directory error")
        } catch {
            XCTAssertTrue(runner.invocations.isEmpty)
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: outsideDirectory,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testLargeInputPreparationRunsOffMainActorWithoutBlockingMainActor() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "responsive-preparation.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try createCanonicalWorkbookOutputs(in: bundleURL)
        let gate = WorkbookInputPreparationGate()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: try successPayloadJSON(for: bundleURL),
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner,
            inputPreparationObserver: { event in
                guard event == .started else { return }
                gate.enterAndWaitForRelease()
            }
        )
        let calls = (0..<20_000).map { index in
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-\(index)",
                locus: "MHC-A",
                haplotype1: "A-\(index)-1",
                haplotype2: "A-\(index)-2",
                status: "called",
                notes: String(repeating: "reviewed ", count: 8)
            )
        }

        let update = Task {
            try await service.run(
                bundleURL: bundleURL,
                calls: calls,
                annotationSidecarURL: nil
            )
        }
        while !gate.hasEntered {
            await Task.yield()
        }

        XCTAssertFalse(gate.workerWasMainThread)
        // Reaching this MainActor-isolated assertion while preparation is held
        // proves the large-input worker did not monopolize the UI executor.
        MainActor.assertIsolated()
        gate.release()
        _ = try await update.value
    }

    func testPreparationFailureRemovesRequestDirectoryButRetainsSharedUpdatesDirectory() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "failed-preparation.lungfishgenotype",
            isDirectory: true
        )
        let updatesURL = bundleURL.appendingPathComponent(
            "artifacts/workbooks/updates",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
            standardError: ""
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner,
            inputPreparationObserver: { event in
                if event == .snapshotDirectoryCreated {
                    throw WorkbookInputPreparationTestError.injected
                }
            }
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: nil
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: updatesURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: updatesURL,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testStagingDirectoryOpenFailureRemovesNewDirectoryEntry() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "failed-staging-open.lungfishgenotype",
            isDirectory: true
        )
        let updatesURL = bundleURL.appendingPathComponent(
            "artifacts/workbooks/updates",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
            standardError: ""
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner,
            stagingDirectoryOpener: { _, _ in
                errno = EACCES
                return -1
            }
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: nil
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: updatesURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: updatesURL,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testCLIFailureRemovesRequestDirectoryButRetainsSharedUpdatesDirectory() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "failed-cli.lungfishgenotype",
            isDirectory: true
        )
        let updatesURL = bundleURL.appendingPathComponent(
            "artifacts/workbooks/updates",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 70,
            standardOutput: "",
            standardError: "publication failed"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: nil
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: updatesURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: updatesURL,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testInvalidAnnotationBytesFailBeforeCLIWithoutWritingEmptySidecar() async throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bundleURL = temp.appendingPathComponent(
            "invalid-annotation.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
            standardError: ""
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        await XCTAssertThrowsErrorAsync {
            try await service.run(
                bundleURL: bundleURL,
                calls: [],
                annotationSidecarURL: bundleURL.appendingPathComponent("annotations.json"),
                annotationSidecarData: Data()
            )
        }

        XCTAssertTrue(runner.invocations.isEmpty)
        let updatesURL = bundleURL.appendingPathComponent(
            "artifacts/workbooks/updates",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: updatesURL.path) {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    at: updatesURL,
                    includingPropertiesForKeys: nil
                ),
                []
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCurrentWorkbookUpdateExecutionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func annotationData(editor: String) throws -> Data {
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T00:00:00Z"
        )
        sidecar.lastEditor = editor
        return try sidecar.encoded()
    }

    private func createCanonicalWorkbookOutputs(in bundleURL: URL) throws {
        let workbookURL = canonicalWorkbookURL(for: bundleURL)
        try FileManager.default.createDirectory(
            at: workbookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: canonicalManifestURL(for: bundleURL))
    }

    private func retainedInputSnapshots(in bundleURL: URL) throws -> [URL] {
        let updatesURL = bundleURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("workbooks", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: updatesURL,
            includingPropertiesForKeys: nil
        ).filter { $0.hasDirectoryPath }
    }

    private func canonicalWorkbookURL(for bundleURL: URL) -> URL {
        bundleURL.standardizedFileURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx", isDirectory: false)
            .standardizedFileURL
    }

    private func canonicalManifestURL(for bundleURL: URL) -> URL {
        bundleURL.standardizedFileURL
            .appendingPathComponent("manifest.json", isDirectory: false)
            .standardizedFileURL
    }

    private func successPayloadJSON(
        for bundleURL: URL,
        cleanupPending: Bool = false,
        warning: String? = nil,
        includeCleanupFields: Bool = true
    ) throws -> String {
        try payloadJSON(
            bundlePath: bundleURL.standardizedFileURL.path,
            workbookPath: canonicalWorkbookURL(for: bundleURL).path,
            manifestPath: canonicalManifestURL(for: bundleURL).path,
            cleanupPending: cleanupPending,
            warning: warning,
            includeCleanupFields: includeCleanupFields
        )
    }

    private func payloadJSON(
        bundlePath: String,
        workbookPath: String,
        manifestPath: String,
        cleanupPending: Bool = false,
        warning: String? = nil,
        includeCleanupFields: Bool = true
    ) throws -> String {
        var object: [String: Any] = [
            "bundlePath": bundlePath,
            "currentWorkbookPath": workbookPath,
            "manifestPath": manifestPath,
        ]
        if includeCleanupFields {
            object["cleanupPending"] = cleanupPending
            if let warning {
                object["warning"] = warning
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            throw NSError(
                domain: "GenotypeCurrentWorkbookUpdateExecutionServiceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(flag)"]
            )
        }
        return arguments[arguments.index(after: index)]
    }

    private func values(after flag: String, in arguments: [String]) throws -> [String] {
        var values: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == flag {
                let valueIndex = arguments.index(after: index)
                guard arguments.indices.contains(valueIndex) else {
                    throw NSError(
                        domain: "GenotypeCurrentWorkbookUpdateExecutionServiceTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing value after \(flag)"]
                    )
                }
                values.append(arguments[valueIndex])
                index = arguments.index(after: valueIndex)
            } else {
                index = arguments.index(after: index)
            }
        }
        return values
    }
}

private enum WorkbookInputPreparationTestError: Error {
    case injected
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private final class WorkbookInputPreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var mainThread = true
    private var released = false

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    var workerWasMainThread: Bool {
        condition.withLock { mainThread }
    }

    func enterAndWaitForRelease() {
        condition.lock()
        entered = true
        mainThread = Thread.isMainThread
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class StubGenotypeWorkbookUpdateCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: LocalWorkflowCLIProcessResult
    let onInvocation: ((Invocation) throws -> Void)?

    init(
        result: LocalWorkflowCLIProcessResult,
        onInvocation: ((Invocation) throws -> Void)? = nil
    ) {
        self.result = result
        self.onInvocation = onInvocation
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        let invocation = Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL
        )
        invocations.append(invocation)
        try onInvocation?(invocation)
        if let outputHandler {
            for line in result.standardError.split(whereSeparator: \.isNewline) {
                outputHandler(.standardError(String(line)))
            }
            for line in result.standardOutput.split(whereSeparator: \.isNewline) {
                outputHandler(.standardOutput(String(line)))
            }
        }
        return LocalWorkflowCLIProcessResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            didStreamOutput: outputHandler != nil
        )
    }
}
