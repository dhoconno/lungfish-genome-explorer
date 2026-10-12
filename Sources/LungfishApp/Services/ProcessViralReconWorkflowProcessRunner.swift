// ProcessViralReconWorkflowProcessRunner.swift - Runs lungfish-cli for the Viral Recon and Local Workflow routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

final class ProcessViralReconWorkflowProcessRunner: ViralReconWorkflowProcessRunning {
    private let executableURL: URL?
    private let cancellationHandle = NativeProcessCancellationHandle()

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
        process.environment = ManagedStorageConfigStore().subprocessEnvironment()
        let collector = ProcessOutputCollector(outputHandler: outputHandler)
        if let cliURL = executableURL ?? Self.lungfishCLIURL() {
            process.executableURL = cliURL
            process.arguments = arguments
        } else {
            throw LungfishCLIRunner.RunError.cliNotFound
        }
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        cancellationHandle.store(process)

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
            collector.append(
                stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                source: .standardOutput
            )
            collector.append(
                stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                source: .standardError
            )
            collector.flushPendingLines()
            termination.finish(process.terminationStatus)
        }

        do {
            try process.run()
            cancellationHandle.terminateIfRequested()
        } catch {
            cancellationHandle.clear(process)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let exitCode = await termination.wait()
        cancellationHandle.clear(process)
        return ViralReconWorkflowProcessResult(
            exitCode: exitCode,
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            didStreamOutput: collector.didStreamOutput
        )
    }

    private static func lungfishCLIURL() -> URL? {
        CLIBinaryLocator.cliBinaryPath()
    }

    func cancel() {
        cancellationHandle.requestProcessTreeTermination(gracePeriod: 0)
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
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                outputHandler(output)
            }
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
