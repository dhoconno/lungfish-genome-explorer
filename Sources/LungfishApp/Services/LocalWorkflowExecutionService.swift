import Foundation
import LungfishWorkflow

@MainActor
final class LocalWorkflowExecutionService {
    struct RunResult {
        let operationID: UUID
        let bundleURL: URL
        let operationItem: OperationCenter.Item?
    }

    private let operationCenter: OperationCenter
    private let processRunner: LocalWorkflowCLIProcessRunning

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: LocalWorkflowCLIProcessRunning = ProcessLocalWorkflowCLIProcessRunner()
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
    }

    func prepare(_ request: LocalWorkflowRunRequest, bundleRoot: URL) async throws -> RunResult {
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let bundleURL = try availableBundleURL(for: request, in: bundleRoot)
        let createdAt = Date()
        let preparedEvent = LocalWorkflowRunStatusEvent(status: .prepared, timestamp: createdAt)
        try LocalWorkflowRunBundleStore.write(
            request.manifest(
                createdAt: createdAt,
                executionStatus: .prepared,
                statusHistory: [preparedEvent]
            ),
            to: bundleURL
        )
        try writePrepareOnlyProvenance(
            request: request,
            bundleURL: bundleURL,
            wallTime: Date().timeIntervalSince(createdAt)
        )

        let commandPreview = cliCommandPreview(for: request, bundleURL: bundleURL, prepareOnly: true)
        let operationID = operationCenter.start(
            title: "Local Workflow",
            detail: "Preparing \(request.engine.displayName) workflow",
            operationType: .workflow,
            targetBundleURL: bundleURL,
            cliCommand: commandPreview
        )
        operationCenter.log(id: operationID, level: .info, message: "Prepared run bundle at \(bundleURL.path)")
        operationCenter.log(id: operationID, level: .info, message: request.commandPreview)
        operationCenter.log(id: operationID, level: .info, message: "Status: prepared")
        operationCenter.log(id: operationID, level: .info, message: commandPreview)
        operationCenter.complete(
            id: operationID,
            detail: "Local workflow prepared. Run bundle: \(bundleURL.path)",
            bundleURLs: [bundleURL]
        )

        return RunResult(
            operationID: operationID,
            bundleURL: bundleURL,
            operationItem: operationCenter.items.first { $0.id == operationID }
        )
    }

    func run(_ request: LocalWorkflowRunRequest, bundleRoot: URL) async throws -> RunResult {
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let bundleURL = try availableBundleURL(for: request, in: bundleRoot)
        let commandPreview = cliCommandPreview(for: request, bundleURL: bundleURL, prepareOnly: false)
        let operationID = operationCenter.start(
            title: "Local Workflow",
            detail: "Running \(request.engine.displayName) workflow",
            operationType: .workflow,
            targetBundleURL: bundleURL,
            cliCommand: commandPreview
        )
        operationCenter.log(id: operationID, level: .info, message: "Run bundle: \(bundleURL.path)")
        operationCenter.log(id: operationID, level: .info, message: request.commandPreview)
        operationCenter.log(id: operationID, level: .info, message: "Status: running")
        operationCenter.log(id: operationID, level: .info, message: commandPreview)

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: request.cliArguments(bundlePath: bundleURL),
                workingDirectory: bundleURL
            )
            logProcessOutput(result, operationID: operationID)
            if result.exitCode == 0 {
                try verifyCompletedRunBundle(at: bundleURL)
                operationCenter.log(id: operationID, level: .info, message: "Status: completed")
                operationCenter.complete(
                    id: operationID,
                    detail: "Local workflow completed. Run bundle: \(bundleURL.path)",
                    bundleURLs: [bundleURL]
                )
            } else {
                let detail = "Local workflow failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: detail)
                operationCenter.fail(
                    id: operationID,
                    detail: detail,
                    errorMessage: "Local workflow failed",
                    errorDetail: result.standardError
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: "Local workflow failed",
                    errorMessage: "Local workflow failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }

        return RunResult(
            operationID: operationID,
            bundleURL: bundleURL,
            operationItem: operationCenter.items.first { $0.id == operationID }
        )
    }

    private func availableBundleURL(for request: LocalWorkflowRunRequest, in root: URL) throws -> URL {
        let base = root.appendingPathComponent(
            "\(request.workflowName).\(LocalWorkflowRunBundleStore.directoryExtension)",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: base.path) else {
            return base
        }

        for index in 2...999 {
            let candidate = root.appendingPathComponent(
                "\(request.workflowName)-\(index).\(LocalWorkflowRunBundleStore.directoryExtension)",
                isDirectory: true
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: base.path])
    }

    private func cliCommandPreview(
        for request: LocalWorkflowRunRequest,
        bundleURL: URL,
        prepareOnly: Bool
    ) -> String {
        ViralReconWorkflowCommandPreview.build(
            executableName: "lungfish-cli",
            arguments: request.cliArguments(bundlePath: bundleURL, prepareOnly: prepareOnly)
        )
    }

    private func logProcessOutput(_ result: LocalWorkflowCLIProcessResult, operationID: UUID) {
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .info, message: String(line))
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .warning, message: String(line))
        }
    }

    private func verifyCompletedRunBundle(at bundleURL: URL) throws {
        let manifest = try LocalWorkflowRunBundleStore.read(from: bundleURL)
        guard manifest.executionStatus == .completed, manifest.exitCode == 0 else {
            throw LocalWorkflowExecutionError.incompleteRunBundle(bundleURL.path)
        }

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard FileManager.default.fileExists(atPath: provenanceURL.path) else {
            throw LocalWorkflowExecutionError.missingProvenance(provenanceURL.path)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
        guard provenance.status == .completed,
              let step = provenance.steps.first,
              step.exitCode == 0,
              !step.command.isEmpty,
              step.outputs.contains(where: { $0.path == bundleURL.standardizedFileURL.path || $0.path == bundleURL.path }) else {
            throw LocalWorkflowExecutionError.invalidProvenance(provenanceURL.path)
        }
    }

    private func writePrepareOnlyProvenance(
        request: LocalWorkflowRunRequest,
        bundleURL: URL,
        wallTime: TimeInterval
    ) throws {
        let command = ["lungfish-cli"] + request.cliArguments(bundlePath: bundleURL, prepareOnly: true)
        let inputs = [ProvenanceRecorder.fileRecord(url: request.workflowURL, format: .text, role: .input)]
            + request.inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) }
        let outputs = [
            FileRecord(path: bundleURL.path, format: .unknown, role: .output),
            FileRecord(path: request.outputDirectory.path, format: .unknown, role: .output),
            ProvenanceRecorder.fileRecord(
                url: bundleURL.appendingPathComponent("manifest.json"),
                format: .json,
                role: .output
            ),
        ]
        var parameters = request.effectiveParams.mapValues { ParameterValue.string($0) }
        parameters["engine"] = .string(request.engine.rawValue)
        parameters["workflowPath"] = .file(request.workflowURL)
        parameters["resume"] = .boolean(request.resume)
        parameters["prepareOnly"] = .boolean(true)
        if let workDirectory = request.workDirectory {
            parameters["workDirectory"] = .file(workDirectory)
        }
        if let cpus = request.cpus {
            parameters["cpus"] = .integer(cpus)
        }
        if let memory = request.memory {
            parameters["memory"] = .string(memory)
        }

        let step = StepExecution(
            toolName: "lungfish-cli workflow run",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: wallTime,
            endTime: Date()
        )
        let run = WorkflowRun(
            name: "Prepare \(request.workflowDisplayName)",
            endTime: Date(),
            status: .completed,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(
            to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            options: .atomic
        )
    }
}

struct LocalWorkflowCLIProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

@MainActor
protocol LocalWorkflowCLIProcessRunning {
    func runLungfishCLI(arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowCLIProcessResult
}

enum LocalWorkflowExecutionError: Error, Equatable {
    case nonZeroExit(Int32)
    case incompleteRunBundle(String)
    case missingProvenance(String)
    case invalidProvenance(String)
}

struct ProcessLocalWorkflowCLIProcessRunner: LocalWorkflowCLIProcessRunning {
    private let runner: ProcessViralReconWorkflowProcessRunner

    init(executableURL: URL? = nil) {
        self.runner = ProcessViralReconWorkflowProcessRunner(executableURL: executableURL)
    }

    func runLungfishCLI(arguments: [String], workingDirectory: URL) async throws -> LocalWorkflowCLIProcessResult {
        let result = try await runner.runLungfishCLI(
            arguments: arguments,
            workingDirectory: workingDirectory,
            outputHandler: nil
        )
        return LocalWorkflowCLIProcessResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }
}
