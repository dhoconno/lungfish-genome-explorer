import Foundation
import LungfishWorkflow

@MainActor
final class NFCoreWorkflowExecutionService {
    struct PreviewRunResult {
        let operationID: UUID
        let bundleURL: URL
        let operationItem: OperationCenter.Item?
    }

    private let operationCenter: OperationCenter
    private let processRunner: NFCoreWorkflowProcessRunning

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: NFCoreWorkflowProcessRunning = ProcessNFCoreWorkflowProcessRunner()
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
    }

    func startPreviewRun(_ request: NFCoreRunRequest, bundleRoot: URL) throws -> PreviewRunResult {
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let bundleURL = try availableBundleURL(for: request.workflow.name, in: bundleRoot)
        try NFCoreRunBundleStore.write(request.manifest(), to: bundleURL)

        let operationID = operationCenter.start(
            title: request.displayTitle,
            detail: "Preparing nf-core workflow run",
            operationType: .nfCoreWorkflow
        )
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Prepared \(request.workflow.fullName) run bundle at \(bundleURL.path)"
        )
        operationCenter.complete(
            id: operationID,
            detail: "Prepared nf-core workflow run bundle",
            bundleURLs: [bundleURL]
        )

        return PreviewRunResult(
            operationID: operationID,
            bundleURL: bundleURL,
            operationItem: operationCenter.items.first { $0.id == operationID }
        )
    }

    func run(_ request: NFCoreRunRequest, bundleRoot: URL) async throws -> PreviewRunResult {
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let bundleURL = try availableBundleURL(for: request.workflow.name, in: bundleRoot)
        try NFCoreRunBundleStore.write(request.manifest(), to: bundleURL)

        let operationID = operationCenter.start(
            title: request.displayTitle,
            detail: "Running nf-core workflow with lungfish-cli",
            operationType: .nfCoreWorkflow
        )
        operationCenter.log(id: operationID, level: .info, message: "Started \(request.workflow.fullName) run")

        do {
            let processResult = try await processRunner.runNextflow(
                arguments: request.cliArguments(bundlePath: bundleURL),
                workingDirectory: bundleRoot
            )
            try writeProcessLogs(processResult, to: bundleURL.appendingPathComponent("logs", isDirectory: true))

            if processResult.exitCode == 0 {
                operationCenter.complete(
                    id: operationID,
                    detail: "nf-core workflow completed",
                    bundleURLs: [bundleURL]
                )
            } else {
                let detail = "nf-core workflow failed with exit code \(processResult.exitCode)"
                operationCenter.fail(
                    id: operationID,
                    detail: detail,
                    errorMessage: detail,
                    errorDetail: processResult.standardError
                )
                throw NFCoreWorkflowExecutionError.nonZeroExit(processResult.exitCode)
            }
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: error.localizedDescription,
                    errorMessage: "nf-core workflow failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }

        return PreviewRunResult(
            operationID: operationID,
            bundleURL: bundleURL,
            operationItem: operationCenter.items.first { $0.id == operationID }
        )
    }

    private func availableBundleURL(for workflowName: String, in root: URL) throws -> URL {
        let safeName = workflowName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let base = root.appendingPathComponent("\(safeName).\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else {
            return base
        }

        for index in 2...999 {
            let candidate = root.appendingPathComponent("\(safeName)-\(index).\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: base.path])
    }

    private func writeProcessLogs(_ result: NFCoreWorkflowProcessResult, to logsURL: URL) throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try result.standardOutput.write(
            to: logsURL.appendingPathComponent("stdout.log"),
            atomically: true,
            encoding: .utf8
        )
        try result.standardError.write(
            to: logsURL.appendingPathComponent("stderr.log"),
            atomically: true,
            encoding: .utf8
        )
    }
}

struct NFCoreWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

@MainActor
protocol NFCoreWorkflowProcessRunning {
    func runNextflow(arguments: [String], workingDirectory: URL) async throws -> NFCoreWorkflowProcessResult
}

enum NFCoreWorkflowExecutionError: Error, Equatable {
    case nonZeroExit(Int32)
}

struct ProcessNFCoreWorkflowProcessRunner: NFCoreWorkflowProcessRunning {
    func runNextflow(arguments: [String], workingDirectory: URL) async throws -> NFCoreWorkflowProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                let captureID = UUID().uuidString
                let stdoutURL = workingDirectory.appendingPathComponent(".nfcore-\(captureID)-stdout.log")
                let stderrURL = workingDirectory.appendingPathComponent(".nfcore-\(captureID)-stderr.log")
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)

                let process = Process()
                if let cliURL = Self.lungfishCLIURL() {
                    process.executableURL = cliURL
                    process.arguments = arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["lungfish-cli"] + arguments
                }
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                process.terminationHandler = { process in
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    let outputData = (try? Data(contentsOf: stdoutURL)) ?? Data()
                    let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
                    try? FileManager.default.removeItem(at: stdoutURL)
                    try? FileManager.default.removeItem(at: stderrURL)
                    continuation.resume(returning: NFCoreWorkflowProcessResult(
                        exitCode: process.terminationStatus,
                        standardOutput: String(data: outputData, encoding: .utf8) ?? "",
                        standardError: String(data: errorData, encoding: .utf8) ?? ""
                    ))
                }

                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func lungfishCLIURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["LUNGFISH_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/lungfish-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        return nil
    }
}
