// CLIImportRunner - Actor for managing CLI import subprocess
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "CLIImportRunner")

func performCLIOperationCenterUpdate(_ block: @escaping @MainActor @Sendable () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                block()
                continuation.resume()
            }
        }
    }
}

// MARK: - CLIImportEvent

/// A parsed event type that mirrors the JSON events the CLI emits during FASTQ import.
///
/// The CLI process outputs one JSON line per event on stdout. Each line has an `"event"` field
/// that determines the case, plus event-specific payload fields.
public enum CLIImportEvent: Sendable {
    case importStart(sampleCount: Int, recipeName: String?)
    case sampleStart(sample: String, index: Int, total: Int, r1: String, r2: String?)
    case stepStart(sample: String, step: String, stepIndex: Int, totalSteps: Int)
    case stepComplete(sample: String, step: String, durationSeconds: Double)
    case recipeReadDelta(
        sample: String,
        label: String,
        inputReads: Int,
        outputReads: Int,
        readsRemoved: Int,
        percentRemoved: Double
    )
    case sampleComplete(sample: String, bundle: String, durationSeconds: Double, originalBytes: Int64, finalBytes: Int64)
    case sampleSkip(sample: String, reason: String)
    case sampleFailed(sample: String, error: String)
    case importComplete(completed: Int, skipped: Int, failed: Int, totalDurationSeconds: Double)
}

// MARK: - CLIImportRunner

/// Manages a `lungfish-cli import fastq` subprocess, parsing its JSON progress events
/// and forwarding them to ``OperationCenter`` for the Operations Panel display.
public actor CLIImportRunner {

    /// The running CLI process, stored for cancellation support.
    private var process: Process?

    // MARK: - Static: Binary Resolution

    /// Resolves the `lungfish-cli` binary path.
    ///
    /// Delegates to ``CLIBinaryLocator/cliBinaryPath()`` in `LungfishKit`,
    /// the canonical (dependency-free) resolver. Kept here as a thin wrapper so
    /// the existing call sites and tests that reference
    /// `CLIImportRunner.cliBinaryPath()` / `CLIImportRunner.resolveCLIPath(...)`
    /// remain unchanged.
    public static func cliBinaryPath() -> URL? {
        CLIBinaryLocator.cliBinaryPath()
    }

    static func resolveCLIPath(
        mainExecutableURL: URL?,
        currentWorkingDirectoryURL: URL?,
        environment: [String: String] = [:],
        pathLookup: () -> URL?,
        swiftPMBinPathLookup: ((URL) -> URL?)? = nil
    ) -> URL? {
        if let swiftPMBinPathLookup {
            return CLIBinaryLocator.resolveCLIPath(
                mainExecutableURL: mainExecutableURL,
                currentWorkingDirectoryURL: currentWorkingDirectoryURL,
                environment: environment,
                pathLookup: pathLookup,
                swiftPMBinPathLookup: swiftPMBinPathLookup
            )
        }

        return CLIBinaryLocator.resolveCLIPath(
            mainExecutableURL: mainExecutableURL,
            currentWorkingDirectoryURL: currentWorkingDirectoryURL,
            environment: environment,
            pathLookup: pathLookup
        )
    }

    // MARK: - Static: Argument Building

    /// Builds the CLI argument array for `lungfish-cli import fastq`.
    ///
    /// - Parameters:
    ///   - r1: Forward reads file URL.
    ///   - r2: Optional reverse reads file URL (paired-end).
    ///   - projectDirectory: The project directory to import into.
    ///   - platform: Sequencing platform name (e.g. "illumina", "nanopore").
    ///   - recipeName: Optional recipe name (e.g. "vsp2").
    ///   - qualityBinning: Whether to enable quality score binning.
    ///   - optimizeStorage: Whether to optimize storage (omitted flag means enabled).
    ///   - compressionLevel: Compression level (1-9).
    /// - Returns: Array of argument strings suitable for ``Process.arguments``.
    public static func buildCLIArguments(
        r1: URL,
        r2: URL?,
        projectDirectory: URL,
        platform: String,
        recipeName: String?,
        qualityBinning: String,
        optimizeStorage: Bool,
        compressionLevel: String
    ) -> [String] {
        var args = ["import", "fastq", r1.path]

        if let r2 {
            args.append(r2.path)
        }

        args += ["--project", projectDirectory.path]
        args += ["--platform", platform]
        args += ["--format", "json"]
        args += ["--quality-binning", qualityBinning]
        args += ["--compression", compressionLevel]
        args.append("--force")

        if let recipeName {
            args += ["--recipe", recipeName]
        }

        if !optimizeStorage {
            args.append("--no-optimize-storage")
        }

        return args
    }

    /// Builds the display form of a `lungfish-cli` command using the same
    /// argument array passed to ``run(arguments:operationID:projectDirectory:onBundleCreated:onError:)``.
    public nonisolated static func commandLine(arguments: [String]) -> String {
        ([CLICommandIdentity.executableName] + arguments).map { shellEscape($0) }.joined(separator: " ")
    }

    // MARK: - Static: Event Parsing

    /// Parses a single JSON line from the CLI stdout into a ``CLIImportEvent``.
    ///
    /// - Parameter line: A single line of CLI output.
    /// - Returns: The parsed event, or `nil` for non-JSON lines or unknown event types.
    /// - Throws: If JSON parsing fails on a line that starts with `{`.
    public static func parseEvent(from line: String) throws -> CLIImportEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = dict["event"] as? String else {
            return nil
        }

        switch event {
        case "importStart":
            let sampleCount = dict["sampleCount"] as? Int ?? 0
            let recipeName = dict["recipeName"] as? String
            return .importStart(sampleCount: sampleCount, recipeName: recipeName)

        case "sampleStart":
            return .sampleStart(
                sample: dict["sample"] as? String ?? "",
                index: dict["index"] as? Int ?? 0,
                total: dict["total"] as? Int ?? 0,
                r1: dict["r1"] as? String ?? "",
                r2: dict["r2"] as? String
            )

        case "stepStart":
            return .stepStart(
                sample: dict["sample"] as? String ?? "",
                step: dict["step"] as? String ?? "",
                stepIndex: dict["stepIndex"] as? Int ?? 0,
                totalSteps: dict["totalSteps"] as? Int ?? 0
            )

        case "stepComplete":
            return .stepComplete(
                sample: dict["sample"] as? String ?? "",
                step: dict["step"] as? String ?? "",
                durationSeconds: dict["durationSeconds"] as? Double ?? 0
            )

        case "recipeReadDelta":
            return .recipeReadDelta(
                sample: dict["sample"] as? String ?? "",
                label: dict["label"] as? String ?? "",
                inputReads: dict["inputReads"] as? Int ?? 0,
                outputReads: dict["outputReads"] as? Int ?? 0,
                readsRemoved: dict["readsRemoved"] as? Int ?? 0,
                percentRemoved: dict["percentRemoved"] as? Double ?? 0
            )

        case "sampleComplete":
            return .sampleComplete(
                sample: dict["sample"] as? String ?? "",
                bundle: dict["bundle"] as? String ?? "",
                durationSeconds: dict["durationSeconds"] as? Double ?? 0,
                originalBytes: (dict["originalBytes"] as? NSNumber)?.int64Value ?? 0,
                finalBytes: (dict["finalBytes"] as? NSNumber)?.int64Value ?? 0
            )

        case "sampleSkip":
            return .sampleSkip(
                sample: dict["sample"] as? String ?? "",
                reason: dict["reason"] as? String ?? ""
            )

        case "sampleFailed":
            return .sampleFailed(
                sample: dict["sample"] as? String ?? "",
                error: dict["error"] as? String ?? ""
            )

        case "importComplete":
            return .importComplete(
                completed: dict["completed"] as? Int ?? 0,
                skipped: dict["skipped"] as? Int ?? 0,
                failed: dict["failed"] as? Int ?? 0,
                totalDurationSeconds: dict["totalDurationSeconds"] as? Double ?? 0
            )

        default:
            logger.debug("Unknown CLI event type: \(event, privacy: .public)")
            return nil
        }
    }

    // MARK: - Instance: Run

    /// Spawns the CLI process and streams its JSON events to ``OperationCenter``.
    ///
    /// - Parameters:
    ///   - arguments: CLI arguments (from ``buildCLIArguments``).
    ///   - operationID: The ``OperationCenter`` operation ID to update.
    ///   - projectDirectory: Project directory for resolving bundle paths.
    ///   - onBundleCreated: Called on the main actor when a sample bundle is created.
    ///   - onError: Called on the main actor when an error occurs.
    public func run(
        arguments: [String],
        operationID: UUID,
        projectDirectory: URL,
        onBundleCreated: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async {
        guard let binaryURL = Self.cliBinaryPath() else {
            let msg = "lungfish-cli binary not found"
            logger.error("\(msg, privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(id: operationID, detail: msg, errorMessage: msg)
                }
            }
            onError(msg)
            return
        }

        logger.info("Launching CLI: \(binaryURL.path, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        self.process = proc
        NativeProcessRegistry.shared.register(proc)
        defer {
            NativeProcessRegistry.shared.unregister(proc)
            if self.process === proc {
                self.process = nil
            }
        }

        // Update status before launching so the user sees we're past the slot wait
        let opID = operationID
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = OperationCenter.shared.update(
                    id: opID,
                    progress: 0.01,
                    detail: "Launching import pipeline\u{2026}"
                )
            }
        }

        await withTaskCancellationHandler {
            // Stream stdout line-by-line for real-time progress updates.
            // We use readabilityHandler on a GCD dispatch source so events
            // reach OperationCenter as the CLI emits them, not after exit.
            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading
            let stdoutHandlerGroup = DispatchGroup()
            let stderrHandlerGroup = DispatchGroup()

            // Mutable state shared across the @Sendable readabilityHandler callback.
            final class StreamState: @unchecked Sendable {
                var stdoutBuffer = Data()
                var stderrBuffer = Data()
                var totalSamples = 1
                var lastSampleFailure: String?
            }
            let state = OSAllocatedUnfairLock(initialState: StreamState())

            @Sendable func handleStdoutLine(_ lineStr: String) {
                do {
                    guard let event = try Self.parseEvent(from: lineStr) else { return }

                    switch event {
                    case let .importStart(sampleCount, _):
                        state.withLock { $0.totalSamples = max(sampleCount, 1) }

                    case let .sampleStart(sample, index, total, _, _):
                        let currentTotal = state.withLock { current -> Int in
                            current.totalSamples = max(total, 1)
                            return current.totalSamples
                        }
                        let progress = Double(index) / Double(currentTotal)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = OperationCenter.shared.update(
                                    id: opID,
                                    progress: progress * 0.05,
                                    detail: "Importing \(sample) (\(index + 1)/\(currentTotal))"
                                )
                            }
                        }

                    case let .stepStart(sample, step, stepIndex, totalSteps):
                        // stepIndex is 1-based from the CLI
                        let fraction = Double(stepIndex) / Double(max(1, totalSteps))
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = OperationCenter.shared.update(
                                    id: opID,
                                    progress: fraction * 0.80,
                                    detail: "\(sample): \(step)"
                                )
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .info,
                                    message: "\(sample) — step \(stepIndex)/\(totalSteps): \(step)"
                                )
                            }
                        }

                    case let .stepComplete(sample, step, durationSeconds):
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .info,
                                    message: "\(sample) — \(step) completed (\(String(format: "%.1f", durationSeconds))s)"
                                )
                            }
                        }

                    case let .recipeReadDelta(sample, label, inputReads, outputReads, _, _):
                        let summary = RecipeAppliedInfo.ReadDeltaSummary(
                            inputReads: inputReads,
                            outputReads: outputReads
                        )
                        let message = RecipeAppliedInfo.readDeltaLogLine(label, summary)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .info,
                                    message: "\(sample) — \(message)"
                                )
                            }
                        }

                    case let .sampleComplete(sample, bundle, _, _, _):
                        let bundleURL = projectDirectory
                            .appendingPathComponent("Imports")
                            .appendingPathComponent(bundle)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .info,
                                    message: "\(sample) — bundle created"
                                )
                            }
                        }
                        onBundleCreated(bundleURL)

                    case let .sampleSkip(sample, reason):
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .warning,
                                    message: "\(sample) skipped: \(reason)"
                                )
                            }
                        }

                    case let .sampleFailed(sample, error):
                        let failureSummary = "\(sample): \(error)"
                        state.withLock { $0.lastSampleFailure = failureSummary }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .error,
                                    message: "\(sample) failed: \(error)"
                                )
                            }
                        }
                        onError(failureSummary)

                    case let .importComplete(completed, skipped, failed, totalDurationSeconds):
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: opID,
                                    level: .info,
                                    message: "Import complete — \(completed) done, \(skipped) skipped, \(failed) failed (\(String(format: "%.1f", totalDurationSeconds))s)"
                                )
                            }
                        }
                    }
                } catch {
                    logger.warning("Failed to parse CLI event: \(error.localizedDescription, privacy: .public)")
                }
            }

            @Sendable func consumeStdout(_ chunk: Data) {
                guard !chunk.isEmpty else { return }
                let lines = state.withLock { current -> [String] in
                    current.stdoutBuffer.append(chunk)
                    var parsed: [String] = []
                    while let newlineRange = current.stdoutBuffer.range(of: Data("\n".utf8)) {
                        let lineData = current.stdoutBuffer.subdata(
                            in: current.stdoutBuffer.startIndex..<newlineRange.lowerBound
                        )
                        current.stdoutBuffer.removeSubrange(current.stdoutBuffer.startIndex..<newlineRange.upperBound)
                        guard let line = String(data: lineData, encoding: .utf8),
                              !line.isEmpty else { continue }
                        parsed.append(line)
                    }
                    return parsed
                }
                for line in lines {
                    handleStdoutLine(line)
                }
            }

            @Sendable func consumeStderr(_ chunk: Data) {
                guard !chunk.isEmpty else { return }
                state.withLock { $0.stderrBuffer.append(chunk) }
            }

            @Sendable func finishStdout() {
                let trailing = state.withLock { current -> String? in
                    guard !current.stdoutBuffer.isEmpty else { return nil }
                    let lineData = current.stdoutBuffer
                    current.stdoutBuffer.removeAll(keepingCapacity: false)
                    return String(data: lineData, encoding: .utf8)
                }
                if let trailing, !trailing.isEmpty {
                    handleStdoutLine(trailing)
                }
            }

            func drainStreamHandlers() {
                stdoutHandlerGroup.wait()
                stderrHandlerGroup.wait()
            }

            // Collect stderr in background to avoid pipe deadlock
            stderrHandle.readabilityHandler = { handle in
                stderrHandlerGroup.enter()
                defer { stderrHandlerGroup.leave() }
                let chunk = handle.availableData
                consumeStderr(chunk)
            }

            // Process stdout lines as they arrive
            stdoutHandle.readabilityHandler = { handle in
                stdoutHandlerGroup.enter()
                defer { stdoutHandlerGroup.leave() }
                let chunk = handle.availableData
                consumeStdout(chunk)
            }

            do {
                try proc.run()
            } catch {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                drainStreamHandlers()
                let msg = "Failed to launch CLI process: \(error.localizedDescription)"
                logger.error("\(msg, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(id: opID, detail: msg, errorMessage: msg)
                    }
                }
                onError(msg)
                return
            }

            proc.waitUntilExit()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            drainStreamHandlers()
            consumeStdout(Self.readAvailableDataNonBlocking(from: stdoutHandle))
            consumeStderr(Self.readAvailableDataNonBlocking(from: stderrHandle))
            finishStdout()

            // Handle non-zero exit
            let exitStatus = proc.terminationStatus
            if exitStatus != 0 {
                let snapshot = state.withLock { current in
                    (
                        stderr: String(data: current.stderrBuffer, encoding: .utf8) ?? "",
                        lastSampleFailure: current.lastSampleFailure
                    )
                }
                let stderrOutput = snapshot.stderr
                let trimmedStderr = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                let exitSummary = "CLI exited with status \(exitStatus)"
                let msg = snapshot.lastSampleFailure ?? exitSummary
                let detailParts = [exitSummary, trimmedStderr]
                    .filter { !$0.isEmpty }
                let errorDetail = detailParts.isEmpty ? nil : detailParts.joined(separator: "\n\n")
                logger.error("\(exitSummary, privacy: .public): \(stderrOutput, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(
                            id: opID,
                            detail: msg,
                            errorMessage: msg,
                            errorDetail: errorDetail
                        )
                    }
                }
                onError(msg)
            }
        } onCancel: {
            Task {
                await self.cancel()
            }
        }
    }

    /// Reads bytes currently available from a pipe without waiting for EOF.
    ///
    /// Some wrapped tools can leave descendants alive with inherited stdout/stderr
    /// descriptors after `lungfish-cli` exits. Waiting for EOF in that case keeps
    /// the GUI import slot open even though the parent CLI command has finished.
    private nonisolated static func readAvailableDataNonBlocking(from handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let originalFlags = fcntl(fd, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
            }
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fd, baseAddress, rawBuffer.count)
            }

            if byteCount > 0 {
                output.append(contentsOf: buffer.prefix(byteCount))
                continue
            }

            if byteCount == 0 {
                break
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            break
        }
        return output
    }

    // MARK: - Instance: Cancel

    /// Terminates the running CLI process tree, if any.
    public func cancel() {
        guard let proc = process else { return }
        logger.info("Terminating CLI process tree rooted at \(proc.processIdentifier, privacy: .public)")
        ProcessTreeTerminator.terminate(rootProcess: proc)
    }
}
