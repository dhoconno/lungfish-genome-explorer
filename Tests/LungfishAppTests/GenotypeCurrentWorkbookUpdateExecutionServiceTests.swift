import XCTest
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
            standardOutput: #"{"bundlePath":"\#(bundleURL.path)"}"#,
            standardError: "[100%] Updated current.xlsx\n"
        ))
        let service = GenotypeCurrentWorkbookUpdateExecutionService(
            operationCenter: operationCenter,
            processRunner: runner
        )
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint(
            schemaVersion: GenotypeCurrentWorkbookInputFingerprint.schemaVersion,
            sha256: String(repeating: "b", count: 64)
        )

        try await service.run(
            bundleURL: bundleURL,
            calls: calls,
            includedLoci: ["MHC-A", "MHC-DP"],
            annotationSidecarURL: annotationURL,
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
        XCTAssertEqual(invocation.arguments.filter { $0 == "--sync-intent" }.count, 1)
        XCTAssertEqual(try value(after: "--input-fingerprint", in: invocation.arguments), fingerprint.sha256)
        XCTAssertEqual(
            try value(after: "--input-fingerprint-schema", in: invocation.arguments),
            String(fingerprint.schemaVersion)
        )
        XCTAssertEqual(try value(after: "--sync-intent", in: invocation.arguments), "update-and-view")

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "Update current.xlsx")
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.targetBundleURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq update-current-workbook") == true)
        XCTAssertTrue(item.cliCommand?.contains("--included-locus MHC-A --included-locus MHC-DP") == true)
        XCTAssertTrue(item.cliCommand?.contains("--input-fingerprint \(fingerprint.sha256)") == true)
        XCTAssertTrue(item.cliCommand?.contains("--input-fingerprint-schema 1") == true)
        XCTAssertTrue(item.cliCommand?.contains("--sync-intent update-and-view") == true)
        XCTAssertTrue(item.cliCommand?.contains(retainedAnnotationURL.path) == true)
        XCTAssertFalse(item.cliCommand?.contains(annotationURL.path) == true)
        XCTAssertTrue(item.outputURLs.contains(bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx").standardizedFileURL))
        XCTAssertTrue(item.logEntries.contains { $0.message == "Updated current.xlsx" })
        XCTAssertTrue(item.logEntries.contains { $0.message == "Included loci: MHC-A, MHC-DP" })
        XCTAssertTrue(item.logEntries.contains {
            $0.message == "Annotations: \(retainedAnnotationURL.path)"
        })
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
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
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
        let liveAnnotationURL = bundleURL.appendingPathComponent("annotations.json")
        let admittedA = try annotationData(editor: "analyst-a")
        let admittedB = try annotationData(editor: "analyst-b")
        try admittedA.write(to: liveAnnotationURL)

        var annotationPayloadsSeenByCLI: [Data] = []
        var annotationURLsSeenByCLI: [URL] = []
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
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
        let gate = WorkbookInputPreparationGate()
        let runner = StubGenotypeWorkbookUpdateCLIProcessRunner(result: .init(
            exitCode: 0,
            standardOutput: "{}",
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
