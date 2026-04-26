import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class NFCoreWorkflowExecutionServiceTests: XCTestCase {
    func testStartingPreviewRunCreatesRunBundleAndOperationCenterItem() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "seqinspector"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfcore-execution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "1.0.0",
            executor: .docker,
            inputURLs: [root.appendingPathComponent("reads.fastq.gz")],
            outputDirectory: root.appendingPathComponent("results", isDirectory: true)
        )
        let service = NFCoreWorkflowExecutionService(operationCenter: OperationCenter())

        let result = try service.startPreviewRun(request, bundleRoot: root)

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.workflowName, "seqinspector")
        XCTAssertEqual(manifest.executor, .docker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(result.operationItem?.operationType, .nfCoreWorkflow)
        XCTAssertEqual(result.operationItem?.title, "Run nf-core/seqinspector")
        XCTAssertEqual(result.operationItem?.detail, "Prepared nf-core workflow run bundle")
        XCTAssertTrue(result.operationItem?.cliCommand?.contains("nextflow run nf-core/seqinspector") == true)
        XCTAssertEqual(result.operationItem?.bundleURLs, [result.bundleURL])
    }

    func testRunUsesInjectedNextflowRunnerAndPersistsLogsInRunBundle() async throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "fetchngs"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfcore-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "1.13.0",
            executor: .conda,
            inputURLs: [URL(fileURLWithPath: "/tmp/samplesheet.csv")],
            outputDirectory: root.appendingPathComponent("results", isDirectory: true)
        )
        let runner = FakeNFCoreWorkflowProcessRunner(result: NFCoreWorkflowProcessResult(
            exitCode: 0,
            standardOutput: "pipeline completed",
            standardError: "nextflow warning"
        ))
        let service = NFCoreWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: runner
        )

        let result = try await service.run(request, bundleRoot: root)

        XCTAssertEqual(runner.invocations.first?.arguments, request.nextflowArguments)
        XCTAssertEqual(runner.invocations.first?.workingDirectory, result.bundleURL.appendingPathComponent("outputs", isDirectory: true))
        XCTAssertEqual(result.operationItem?.state, .completed)
        XCTAssertEqual(result.operationItem?.detail, "nf-core workflow completed")
        XCTAssertEqual(result.operationItem?.bundleURLs, [result.bundleURL])
        XCTAssertEqual(
            try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stdout.log")),
            "pipeline completed"
        )
        XCTAssertEqual(
            try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stderr.log")),
            "nextflow warning"
        )
    }
}

@MainActor
private final class FakeNFCoreWorkflowProcessRunner: NFCoreWorkflowProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: NFCoreWorkflowProcessResult

    init(result: NFCoreWorkflowProcessResult) {
        self.result = result
    }

    func runNextflow(arguments: [String], workingDirectory: URL) async throws -> NFCoreWorkflowProcessResult {
        invocations.append(Invocation(arguments: arguments, workingDirectory: workingDirectory))
        return result
    }
}
