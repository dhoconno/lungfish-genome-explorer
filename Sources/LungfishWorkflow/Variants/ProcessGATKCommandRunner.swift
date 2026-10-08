// ProcessGATKCommandRunner.swift - Runs a GATK command as a local process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

private final class GATKDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public struct ProcessGATKCommandRunner: GATKCommandRunning {
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(environment: [String: String] = [:], timeout: TimeInterval = 24 * 60 * 60) {
        self.environment = environment
        self.timeout = timeout
    }

    public func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        try await runGATKProcess(command, environment: environment, timeout: timeout)
    }
}

/// Runs a native `Process` for a GATK command with Task-cancellation and timeout
/// wiring (R3-R3ML-14), matching the house idiom used elsewhere in `LungfishWorkflow`
/// (e.g. `PBAAClusteringPipeline.runProcess`, `MappingSummaryBuilder.runProcessCapturingOutput`):
/// `withTaskCancellationHandler` + `NativeProcessCancellationHandle` +
/// `NativeProcessRunState`, with an async `process.terminationHandler` draining
/// stdout/stderr on background queues before resuming. Previously this ran inside a
/// plain `Task.detached` with a synchronous `process.waitUntilExit()` and no
/// cancellation/timeout enforcement at all: if the underlying process hung or the
/// enclosing Task was cancelled, there was no code path to terminate the child.
private func runGATKProcess(
    _ command: GATKCommand,
    environment: [String: String],
    timeout: TimeInterval
) async throws -> GATKCommandExecutionResult {
    let cancellationHandle = NativeProcessCancellationHandle()
    let runState = NativeProcessRunState()
    let commandClock = ProvenanceRunClock()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            if command.executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command.executable] + command.arguments
            }
            if let workingDirectory = command.workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutBox = GATKDataBox()
            let stderrBox = GATKDataBox()
            let drainGroup = DispatchGroup()
            let startOutputDrain: @Sendable () -> Void = {
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }
            }
            cancellationHandle.store(process)

            // DispatchWorkItem is not Sendable, but it is only ever cancelled from
            // process.terminationHandler/the process.run() catch block below, never
            // concurrently with its own execution (mirrors CondaManager.runTool's
            // timeoutItem, same rationale).
            nonisolated(unsafe) let timeoutWorkItem = DispatchWorkItem {
                runState.markTimedOut()
                cancellationHandle.requestProcessTreeTermination()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            process.terminationHandler = { terminatedProcess in
                drainGroup.notify(queue: .global(qos: .userInitiated)) {
                    timeoutWorkItem.cancel()
                    cancellationHandle.clear(terminatedProcess)
                    runState.resumeOnce { reason in
                        switch reason {
                        case .cancelled, .timedOut:
                            continuation.resume(throwing: CancellationError())
                        case .completed:
                            let wallTime = commandClock.elapsed
                            let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
                            let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
                            continuation.resume(returning: GATKCommandExecutionResult(
                                exitCode: terminatedProcess.terminationStatus,
                                stdout: stdout,
                                stderr: stderr,
                                wallTime: wallTime
                            ))
                        }
                    }
                }
            }

            do {
                startOutputDrain()
                try process.run()
                cancellationHandle.terminateIfRequested()
                if runState.isCancelled {
                    cancellationHandle.requestProcessTreeTermination()
                }
            } catch {
                timeoutWorkItem.cancel()
                cancellationHandle.clear(process)
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                runState.resumeOnce { reason in
                    switch reason {
                    case .cancelled, .timedOut:
                        continuation.resume(throwing: CancellationError())
                    case .completed:
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    } onCancel: {
        runState.markCancelled()
        cancellationHandle.requestProcessTreeTermination()
    }
}
