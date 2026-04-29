import Foundation
import LungfishWorkflow

@MainActor
final class ViralReconWorkflowExecutionService {
    struct RunResult {
        let operationID: UUID
        let bundleURL: URL
        let operationItem: OperationCenter.Item?
    }

    private let operationCenter: OperationCenter
    private let processRunner: ViralReconWorkflowProcessRunning

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: ViralReconWorkflowProcessRunning = ProcessViralReconWorkflowProcessRunner()
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
    }

    func run(_ request: ViralReconRunRequest, bundleRoot: URL) async throws -> RunResult {
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let bundleURL = try availableBundleURL(in: bundleRoot)
        let persistedRequest = try persistGeneratedInputs(from: request, in: bundleURL)
        try writeRunBundle(for: persistedRequest, to: bundleURL)

        let commandPreview = cliCommandPreview(for: persistedRequest, bundleURL: bundleURL)
        let operationID = operationCenter.start(
            title: "Viral Recon",
            detail: initialDetail(for: persistedRequest),
            operationType: .viralRecon,
            targetBundleURL: bundleURL,
            cliCommand: commandPreview
        )
        logPreparation(for: persistedRequest, bundleURL: bundleURL, commandPreview: commandPreview, operationID: operationID)

        do {
            let processResult = try await processRunner.runLungfishCLI(
                arguments: persistedRequest.cliArguments(bundlePath: bundleURL),
                workingDirectory: bundleURL,
                outputHandler: { [operationCenter] output in
                    switch output {
                    case .standardOutput(let line):
                        operationCenter.log(id: operationID, level: .info, message: line)
                    case .standardError(let line):
                        operationCenter.log(id: operationID, level: .warning, message: line)
                    }
                }
            )
            try writeProcessLogs(processResult, to: bundleURL.appendingPathComponent("logs", isDirectory: true))
            if !processResult.didStreamOutput {
                logProcessOutput(processResult, operationID: operationID)
            }

            if processResult.exitCode == 0 {
                operationCenter.log(id: operationID, level: .info, message: "Viral Recon completed")
                operationCenter.complete(
                    id: operationID,
                    detail: completionDetail(for: persistedRequest, bundleURL: bundleURL),
                    bundleURLs: [bundleURL]
                )
            } else {
                let tail = stderrTail(processResult.standardError)
                let failureDetail = failureDetail(exitCode: processResult.exitCode, stderrTail: tail)
                operationCenter.log(
                    id: operationID,
                    level: .error,
                    message: "Viral Recon failed with exit code \(processResult.exitCode)"
                )
                operationCenter.fail(
                    id: operationID,
                    detail: failureDetail,
                    errorMessage: "Viral Recon failed",
                    errorDetail: "exit code \(processResult.exitCode)\n\n\(tail)"
                )
                throw ViralReconWorkflowExecutionError.nonZeroExit(processResult.exitCode)
            }
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: "Viral Recon failed",
                    errorMessage: "Viral Recon failed",
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

    private func persistGeneratedInputs(from request: ViralReconRunRequest, in bundleURL: URL) throws -> ViralReconRunRequest {
        let inputsURL = bundleURL.appendingPathComponent("inputs", isDirectory: true)
        let primersURL = inputsURL.appendingPathComponent("primers", isDirectory: true)
        let nanoporeURL = inputsURL.appendingPathComponent("nanopore", isDirectory: true)
        try FileManager.default.createDirectory(at: primersURL, withIntermediateDirectories: true)

        let samplesheetURL = inputsURL.appendingPathComponent("samplesheet.csv")
        let primerBEDURL = primersURL.appendingPathComponent("primers.bed")
        let primerFASTAURL = primersURL.appendingPathComponent("primers.fasta")
        try copyItem(from: request.samplesheetURL, to: samplesheetURL)
        try copyItem(from: request.primer.bedURL, to: primerBEDURL)
        try copyItem(from: request.primer.fastaURL, to: primerFASTAURL)

        var fastqPassDirectoryURL: URL?
        var sequencingSummaryURL: URL?
        if request.platform == .nanopore {
            if let sourceFastqPass = request.fastqPassDirectoryURL {
                try FileManager.default.createDirectory(at: nanoporeURL, withIntermediateDirectories: true)
                let destinationFastqPass = nanoporeURL.appendingPathComponent("fastq_pass", isDirectory: true)
                try copyItem(from: sourceFastqPass, to: destinationFastqPass)
                fastqPassDirectoryURL = destinationFastqPass
            }
            if let sourceSummary = request.sequencingSummaryURL {
                try FileManager.default.createDirectory(at: nanoporeURL, withIntermediateDirectories: true)
                let destinationSummary = nanoporeURL.appendingPathComponent(sourceSummary.lastPathComponent)
                try copyItem(from: sourceSummary, to: destinationSummary)
                sequencingSummaryURL = destinationSummary
            }
        }

        let primer = ViralReconPrimerSelection(
            bundleURL: request.primer.bundleURL,
            displayName: request.primer.displayName,
            bedURL: primerBEDURL,
            fastaURL: primerFASTAURL,
            leftSuffix: request.primer.leftSuffix,
            rightSuffix: request.primer.rightSuffix,
            derivedFasta: request.primer.derivedFasta
        )

        return try ViralReconRunRequest(
            samples: request.samples,
            platform: request.platform,
            protocol: request.protocol,
            samplesheetURL: samplesheetURL,
            outputDirectory: request.outputDirectory,
            executor: request.executor,
            version: request.version,
            reference: request.reference,
            primer: primer,
            minimumMappedReads: request.minimumMappedReads,
            variantCaller: request.variantCaller,
            consensusCaller: request.consensusCaller,
            skipOptions: request.skipOptions,
            advancedParams: request.advancedParams,
            fastqPassDirectoryURL: fastqPassDirectoryURL ?? request.fastqPassDirectoryURL,
            sequencingSummaryURL: sequencingSummaryURL ?? request.sequencingSummaryURL
        )
    }

    private func writeRunBundle(for request: ViralReconRunRequest, to bundleURL: URL) throws {
        let workflow = try viralReconWorkflow()
        let runRequest = NFCoreRunRequest(
            workflow: workflow,
            version: request.version,
            executor: request.executor,
            inputURLs: [request.samplesheetURL],
            outputDirectory: request.outputDirectory,
            params: request.effectiveParams,
            presentationMode: .customAdapter("viralrecon")
        )
        try NFCoreRunBundleStore.write(runRequest.manifest(), to: bundleURL)

        let inputsURL = bundleURL.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        try data.write(to: inputsURL.appendingPathComponent("viralrecon-request.json"), options: .atomic)
        try request.samplesheetURL.path.write(
            to: inputsURL.appendingPathComponent("samplesheet.path"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func logPreparation(
        for request: ViralReconRunRequest,
        bundleURL: URL,
        commandPreview: String,
        operationID: UUID
    ) {
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Prepared run bundle at \(bundleURL.path)"
        )
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Using samplesheet \(request.samplesheetURL.path)"
        )
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Using primer scheme \(request.primer.displayName) from \(request.primer.bundleURL.path)"
        )
        if request.primer.derivedFasta {
            operationCenter.log(
                id: operationID,
                level: .info,
                message: "Using derived primer FASTA \(request.primer.fastaURL.path)"
            )
        }
        operationCenter.log(id: operationID, level: .info, message: commandPreview)
    }

    private func logProcessOutput(_ result: ViralReconWorkflowProcessResult, operationID: UUID) {
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .info, message: String(line))
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            operationCenter.log(id: operationID, level: .warning, message: String(line))
        }
    }

    private func availableBundleURL(in root: URL) throws -> URL {
        let base = root.appendingPathComponent("viralrecon.\(NFCoreRunBundleStore.directoryExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else {
            return base
        }

        for index in 2...999 {
            let candidate = root.appendingPathComponent(
                "viralrecon-\(index).\(NFCoreRunBundleStore.directoryExtension)",
                isDirectory: true
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: base.path])
    }

    private func viralReconWorkflow() throws -> NFCoreSupportedWorkflow {
        if let workflow = NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon") {
            return workflow
        }
        throw ViralReconWorkflowExecutionError.missingWorkflowDefinition
    }

    private func writeProcessLogs(_ result: ViralReconWorkflowProcessResult, to logsURL: URL) throws {
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

    private func cliCommandPreview(for request: ViralReconRunRequest, bundleURL: URL) -> String {
        ViralReconWorkflowCommandPreview.build(
            executableName: "lungfish-cli",
            arguments: request.cliArguments(bundlePath: bundleURL)
        )
    }

    private func stderrTail(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(40).joined(separator: "\n")
    }

    private func initialDetail(for request: ViralReconRunRequest) -> String {
        "\(request.platform.rawValue) · \(request.samples.count) sample(s) · \(referenceDisplayName(request.reference))"
    }

    private func completionDetail(for request: ViralReconRunRequest, bundleURL: URL) -> String {
        "Viral Recon completed. Output: \(request.outputDirectory.path). Run bundle: \(bundleURL.path)"
    }

    private func failureDetail(exitCode: Int32, stderrTail: String) -> String {
        let trimmedTail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTail.isEmpty else {
            return "Viral Recon failed with exit code \(exitCode)"
        }
        return "Viral Recon failed with exit code \(exitCode). \(trimmedTail)"
    }

    private func referenceDisplayName(_ reference: ViralReconReference) -> String {
        switch reference {
        case .genome(let accession):
            return accession
        case .local(let fastaURL, _):
            return fastaURL.lastPathComponent
        }
    }

    private func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        if source.path == destination.path {
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

enum ViralReconWorkflowCommandPreview {
    static func build(executableName: String, arguments: [String]) -> String {
        ([executableName] + arguments)
            .map(shellEscape)
            .joined(separator: " ")
    }
}

struct ViralReconWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let didStreamOutput: Bool

    init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        didStreamOutput: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.didStreamOutput = didStreamOutput
    }
}

enum ViralReconWorkflowProcessOutput: Sendable, Equatable {
    case standardOutput(String)
    case standardError(String)
}

@MainActor
protocol ViralReconWorkflowProcessRunning {
    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult
}

enum ViralReconWorkflowExecutionError: Error, Equatable {
    case nonZeroExit(Int32)
    case missingWorkflowDefinition
}

struct ProcessViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning {
    private let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        let collector = ProcessOutputCollector(outputHandler: outputHandler)
        if let cliURL = executableURL ?? Self.lungfishCLIURL() {
            process.executableURL = cliURL
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["lungfish-cli"] + arguments
        }
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data, source: .standardOutput)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data, source: .standardError)
        }

        let termination = ProcessTermination()
        process.terminationHandler = { process in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            collector.flushPendingLines()
            termination.finish(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let exitCode = await termination.wait()
        return ViralReconWorkflowProcessResult(
            exitCode: exitCode,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            didStreamOutput: collector.didStreamOutput
        )
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

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutputData = Data()
    private var standardErrorData = Data()
    private var pendingStandardOutput = ""
    private var pendingStandardError = ""
    private var streamedOutput = false
    private let outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?

    init(outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?) {
        self.outputHandler = outputHandler
    }

    var standardOutput: String {
        lock.withLock {
            String(data: standardOutputData, encoding: .utf8) ?? ""
        }
    }

    var standardError: String {
        lock.withLock {
            String(data: standardErrorData, encoding: .utf8) ?? ""
        }
    }

    var didStreamOutput: Bool {
        lock.withLock {
            streamedOutput
        }
    }

    func append(_ data: Data, source: ViralReconWorkflowProcessOutput.Source) {
        guard !data.isEmpty else { return }
        let lines: [String]
        lock.lock()
        switch source {
        case .standardOutput:
            standardOutputData.append(data)
            lines = Self.completeLines(from: data, pending: &pendingStandardOutput)
        case .standardError:
            standardErrorData.append(data)
            lines = Self.completeLines(from: data, pending: &pendingStandardError)
        }
        lock.unlock()

        for line in lines {
            emit(line, source: source)
        }
    }

    func flushPendingLines() {
        let outputLine: String?
        let errorLine: String?
        lock.lock()
        outputLine = pendingStandardOutput.isEmpty ? nil : pendingStandardOutput
        errorLine = pendingStandardError.isEmpty ? nil : pendingStandardError
        pendingStandardOutput = ""
        pendingStandardError = ""
        lock.unlock()

        if let outputLine {
            emit(outputLine, source: .standardOutput)
        }
        if let errorLine {
            emit(errorLine, source: .standardError)
        }
    }

    private func emit(_ line: String, source: ViralReconWorkflowProcessOutput.Source) {
        guard let outputHandler else { return }
        let output: ViralReconWorkflowProcessOutput
        switch source {
        case .standardOutput:
            output = .standardOutput(line)
        case .standardError:
            output = .standardError(line)
        }
        lock.withLock {
            streamedOutput = true
        }
        Task { @MainActor in
            outputHandler(output)
        }
    }

    private static func completeLines(from data: Data, pending: inout String) -> [String] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }

        pending += chunk
        let components = pending.components(separatedBy: .newlines)
        let completeComponents = components.prefix(max(0, components.count - 1))
        if pending.last?.isNewline == true {
            pending = ""
            return Array(completeComponents)
        }

        pending = components.last ?? ""
        return Array(completeComponents)
    }
}

private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var exitCode: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ code: Int32) {
        let continuationToResume: CheckedContinuation<Int32, Never>?
        lock.lock()
        exitCode = code
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: code)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let code: Int32?
            lock.lock()
            code = exitCode
            if code == nil {
                self.continuation = continuation
            }
            lock.unlock()
            if let code {
                continuation.resume(returning: code)
            }
        }
    }
}

private extension ViralReconWorkflowProcessOutput {
    enum Source {
        case standardOutput
        case standardError
    }
}
