import XCTest
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
        try Data("{}".utf8).write(to: annotationURL)
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

        try await service.run(bundleURL: bundleURL, calls: calls, annotationSidecarURL: annotationURL)

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
        XCTAssertEqual(try value(after: "--annotations", in: invocation.arguments), annotationURL.standardizedFileURL.path)

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.title, "Update current.xlsx")
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.targetBundleURL, bundleURL.standardizedFileURL)
        XCTAssertTrue(item.cliCommand?.contains("lungfish-cli fastq update-current-workbook") == true)
        XCTAssertTrue(item.outputURLs.contains(bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx").standardizedFileURL))
        XCTAssertTrue(item.logEntries.contains { $0.message == "Updated current.xlsx" })
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCurrentWorkbookUpdateExecutionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
}

private final class StubGenotypeWorkbookUpdateCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    private(set) var invocations: [Invocation] = []
    let result: LocalWorkflowCLIProcessResult

    init(result: LocalWorkflowCLIProcessResult) {
        self.result = result
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL
        ))
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
