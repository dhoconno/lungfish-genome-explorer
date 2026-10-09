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
    case notice(sample: String, message: String)
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

    /// Non-actor-isolated handle to the running process, used by ``cancel()``
    /// so termination never has to wait for the actor's executor. It also
    /// remembers a cancel that arrives before the launch, so the CLI is then
    /// never launched.
    private let cancellation = CLIRunCancellation(cleanupGrace: .seconds(CLIImportRunner.cleanupGrace))

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
    ///   - unpaired: Optional file of the pair's reads whose mate is missing,
    ///     which the CLI imports with the pair as one sample.
    ///   - projectDirectory: The project directory to import into.
    ///   - platform: Sequencing platform name (e.g. "illumina", "nanopore").
    ///   - recipeName: Optional recipe name (e.g. "vsp2").
    ///   - qualityBinning: Whether to enable quality score binning.
    ///   - optimizeStorage: Whether to optimize storage (omitted flag means enabled).
    ///   - clumpingTool: Storage optimization tool selection.
    ///   - pairingMode: The Import sheet's Pairing choice; `nil` leaves the
    ///     CLI's name-based detection in charge.
    ///   - compressionLevel: Compression level (1-9).
    /// - Returns: Array of argument strings suitable for ``Process.arguments``.
    public static func buildCLIArguments(
        r1: URL,
        r2: URL?,
        unpaired: URL? = nil,
        projectDirectory: URL,
        platform: String,
        recipeName: String?,
        qualityBinning: String,
        optimizeStorage: Bool,
        clumpingTool: ClumpingTool = .default,
        pairingMode: FASTQIngestionConfig.PairingMode? = nil,
        compressionLevel: String,
        bundleName: String? = nil,
        force: Bool = false
    ) -> [String] {
        var args = ["import", "fastq", r1.path]

        if let r2 {
            args.append(r2.path)
        }
        if let unpaired {
            args.append(unpaired.path)
        }

        args += ["--project", projectDirectory.path]
        args += ["--platform", platform]
        if let pairingMode {
            args += ["--pairing", pairingArgument(for: pairingMode)]
        }
        args += ["--format", "json"]
        args += ["--quality-binning", qualityBinning]
        args += ["--compression", compressionLevel]
        // `--force` is only passed after the user has explicitly chosen
        // Replace in the duplicate-file dialog. Passing it
        // unconditionally caused same-named imports to silently overwrite
        // an existing bundle and its derivatives.
        if force {
            args.append("--force")
        }
        if let bundleName, !bundleName.isEmpty {
            args += ["--name", bundleName]
        }

        if let recipeName {
            args += ["--recipe", recipeName]
        }

        if !optimizeStorage || clumpingTool == .none {
            args.append("--no-optimize-storage")
        } else if clumpingTool != .default {
            args += ["--clumping-tool", clumpingTool.rawValue]
        }

        return args
    }

    /// The `--pairing` value for an ingestion pairing mode.
    public static func pairingArgument(for pairingMode: FASTQIngestionConfig.PairingMode) -> String {
        switch pairingMode {
        case .singleEnd: return "single"
        case .pairedEnd: return "paired"
        case .interleaved: return "interleaved"
        }
    }

    /// Builds the display form of a `lungfish-cli` command using the same
    /// argument array passed to ``run(arguments:operationID:projectDirectory:onBundleCreated:onError:)``.
    public nonisolated static func commandLine(arguments: [String]) -> String {
        ([CLICommandIdentity.executableName] + arguments).map { shellEscape($0) }.joined(separator: " ")
    }

    /// The Operations row's line for a `notice` event of `import fastq`.
    /// The Import FASTQ sheet logs its grouping's notices with it too, so a
    /// notice reads the same whichever of the two logs it.
    nonisolated static func noticeLine(sample: String, message: String) -> String {
        "\(sample) — \(message)"
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

        case "notice":
            return .notice(
                sample: dict["sample"] as? String ?? "",
                message: dict["message"] as? String ?? ""
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

        // Mutable state shared across the @Sendable event callback.
        final class StreamState: @unchecked Sendable {
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

                case let .notice(sample, message):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: Self.noticeLine(sample: sample, message: message)
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

        // The output is read until end of file as the CLI writes it, so events
        // reach OperationCenter as the CLI emits them, not after exit. A cancel
        // gives the CLI `cleanupGrace` after SIGTERM to remove its staging
        // folders (see ``CLIRunCancellation``). A tool the CLI started that
        // keeps the output open after the CLI exits is stopped half a second
        // later, so it cannot hold the import slot.
        let spec = ToolProcessSpec(
            executableURL: binaryURL,
            arguments: arguments,
            environment: ManagedStorageConfigStore().subprocessEnvironment(),
            stdout: .capture(limit: 0),
            stderr: .capture(),
            terminationGracePeriod: .zero,
            drainGracePeriod: .milliseconds(500),
            label: "lungfish-cli"
        )
        let outcome = await cancellation.run(spec) { event in
            guard case .output(.stdout, let line) = event, !line.isEmpty else { return }
            handleStdoutLine(line)
        }

        let result: ToolProcessResult
        switch outcome.result {
        case .success(let finished):
            result = finished
        case .failure(.cancelled(let results)), .failure(.timedOut(_, let results)):
            guard let ended = results.first else {
                // A cancel came before the launch, so nothing ran. The
                // caller ends the operation as cancelled.
                logger.info("CLI import cancelled before launch")
                onError("Import cancelled before it started")
                return
            }
            result = ended
        case .failure(let error):
            let msg = "Failed to launch CLI process: \(error.cliLaunchFailureReason)"
            logger.error("\(msg, privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(id: opID, detail: msg, errorMessage: msg)
                }
            }
            onError(msg)
            return
        }

        // Handle a non-zero exit, or an exit whose output a lingering child
        // process cut short.
        let exitStatus = result.status
        let incompleteNote = result.cliIncompleteOutputNote
        if exitStatus != 0 || incompleteNote != nil {
            let snapshot = state.withLock { current in current.lastSampleFailure }
            let stderrOutput = result.cliStderrText
            let trimmedStderr = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let exitSummary = exitStatus != 0 ? "CLI exited with status \(exitStatus)" : (incompleteNote ?? "")
            let msg = snapshot ?? exitSummary
            var detailParts = [exitSummary]
            if exitStatus != 0, let incompleteNote { detailParts.append(incompleteNote) }
            detailParts.append(trimmedStderr)
            detailParts = detailParts.filter { !$0.isEmpty }
            let errorDetail = detailParts.isEmpty ? nil : detailParts.joined(separator: "\n\n")
            logger.error("\(exitSummary, privacy: .public): \(stderrOutput, privacy: .public)")
            // After a cancel the caller ends the operation, once its own
            // cleanup has run, so the row is not ended here first.
            if !outcome.cancelRequested {
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
            }
            onError(msg)
        }
    }

    // MARK: - Instance: Cancel

    /// How long `lungfish-cli` gets after SIGTERM to remove its staging
    /// folders and workspace before it is killed. Inside OperationCenter's
    /// 10 s forced-acknowledge grace period.
    static let cleanupGrace: TimeInterval = 5

    /// Terminates the running CLI process tree, if any, or keeps the CLI
    /// from launching when the cancel comes first.
    ///
    /// Deliberately `nonisolated`: it must be callable — and must complete —
    /// even while `run()` is suspended awaiting the process. It goes through
    /// ``cancellation`` rather than actor-isolated state, so cancellation
    /// never has to wait in line behind the very operation it is trying to
    /// stop. It returns at once. The CLI and its descendants get SIGTERM, and
    /// the CLI has ``cleanupGrace`` seconds to clean up and exit. ToolProcess
    /// then kills whatever is left.
    public nonisolated func cancel() {
        logger.info("Terminating CLI process tree")
        cancellation.cancel()
    }
}
