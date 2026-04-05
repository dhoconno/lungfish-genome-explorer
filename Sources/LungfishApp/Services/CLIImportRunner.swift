// CLIImportRunner - Actor for managing CLI import subprocess
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "CLIImportRunner")

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
    /// Search order:
    /// 1. `<AppBundle>/Contents/MacOS/lungfish-cli` (release)
    /// 2. `.build/debug/lungfish-cli` (development)
    /// 3. PATH lookup via `/usr/bin/which`
    public static func cliBinaryPath() -> URL? {
        // 1. Inside app bundle
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("lungfish-cli") {
            if FileManager.default.isExecutableFile(atPath: bundlePath.path) {
                return bundlePath
            }
        }

        // 2. Development build directory
        let devPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/lungfish-cli")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        // 3. PATH lookup via which
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["lungfish-cli"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return URL(fileURLWithPath: path)
                }
            }
        } catch {
            logger.warning("PATH lookup for lungfish-cli failed: \(error.localizedDescription, privacy: .public)")
        }

        return nil
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
        qualityBinning: Bool,
        optimizeStorage: Bool,
        compressionLevel: Int
    ) -> [String] {
        var args = ["import", "fastq", r1.path]

        if let r2 {
            args.append(r2.path)
        }

        args += ["--project", projectDirectory.path]
        args += ["--platform", platform]
        args += ["--format", "json"]
        args += ["--compression", "\(compressionLevel)"]
        args.append("--force")

        if let recipeName {
            args += ["--recipe", recipeName]
        }

        if qualityBinning {
            args.append("--quality-binning")
        }

        if !optimizeStorage {
            args.append("--no-optimize-storage")
        }

        return args
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
                    OperationCenter.shared.fail(id: operationID, detail: msg, errorMessage: msg)
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

        do {
            try proc.run()
        } catch {
            let msg = "Failed to launch CLI process: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(id: operationID, detail: msg, errorMessage: msg)
                }
            }
            onError(msg)
            return
        }

        // Read all stdout and parse line by line
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: .newlines)

        var totalSamples = 1  // default if importStart not received

        for line in lines {
            guard !line.isEmpty else { continue }

            do {
                guard let event = try Self.parseEvent(from: line) else { continue }

                let opID = operationID
                switch event {
                case let .importStart(sampleCount, _):
                    totalSamples = max(sampleCount, 1)

                case let .sampleStart(sample, index, total, _, _):
                    totalSamples = max(total, 1)
                    let progress = Double(index) / Double(totalSamples)
                    let currentTotal = totalSamples
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: progress,
                                detail: "Importing \(sample) (\(index + 1)/\(currentTotal))"
                            )
                        }
                    }

                case let .stepStart(sample, step, stepIndex, totalSteps):
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.update(
                                id: opID,
                                progress: -1,  // indeterminate within sample
                                detail: "\(sample): \(step)"
                            )
                            OperationCenter.shared.log(
                                id: opID,
                                level: .info,
                                message: "\(sample) — step \(stepIndex + 1)/\(totalSteps): \(step)"
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

                case let .sampleComplete(sample, bundle, _, _, _):
                    let bundleURL = URL(fileURLWithPath: bundle)
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
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .error,
                                message: "\(sample) failed: \(error)"
                            )
                        }
                    }
                    onError("\(sample): \(error)")

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
                logger.warning("Failed to parse CLI event line: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Handle non-zero exit
        let exitStatus = proc.terminationStatus
        if exitStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrOutput = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            let msg = "CLI exited with status \(exitStatus)"
            logger.error("\(msg, privacy: .public): \(stderrOutput, privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.fail(
                        id: operationID,
                        detail: msg,
                        errorMessage: msg,
                        errorDetail: stderrOutput
                    )
                }
            }
            onError("\(msg): \(stderrOutput)")
        }

        self.process = nil
    }

    // MARK: - Instance: Cancel

    /// Sends SIGTERM to the running CLI process, if any.
    public func cancel() {
        guard let proc = process, proc.isRunning else { return }
        logger.info("Sending SIGTERM to CLI process \(proc.processIdentifier, privacy: .public)")
        proc.terminate()
    }
}
