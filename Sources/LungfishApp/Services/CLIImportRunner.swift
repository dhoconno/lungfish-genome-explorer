// CLIImportRunner - Actor for managing CLI import subprocess
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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

// MARK: - CLIImportRunner

/// Manages a `lungfish-cli import fastq` subprocess. It reads the command's
/// version 2 events through ``CLISubprocessTransport`` and shows them on the
/// operation's ``OperationCenter`` row in the Operations Panel.
///
/// Before Phase 2.7 the command printed a private stream, S1, that this actor
/// parsed itself. The events now carry the texts and levels the row showed
/// for S1 (`FASTQImportEventStream` in LungfishWorkflow, lane Q4).
public actor CLIImportRunner {

    /// Runs the CLI. Its ``CLISubprocessTransport/cancel()`` is non-isolated,
    /// so ``cancel()`` never waits for this actor's executor, and it remembers
    /// a cancel that arrives before the launch, so the CLI is then never
    /// launched.
    private let transport = CLISubprocessTransport()

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
    ///   - recipeSwitchOptions: Switch id to value for each recipe switch the user changed from the preset. Each is
    ///     passed as the CLI's own option after `--recipe`, and none is passed without a recipe.
    ///   - qualityBinning: The quality binning the import runs, always passed as `--quality-binning`.
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
        recipeSwitchOptions: [String: Bool] = [:],
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
            args += recipeSwitchArguments(recipeSwitchOptions)
        }

        if !optimizeStorage || clumpingTool == .none {
            args.append("--no-optimize-storage")
        } else if clumpingTool != .default {
            args += ["--clumping-tool", clumpingTool.rawValue]
        }

        return args
    }

    /// The options that set recipe switches, such as `--no-remove-duplicates`, in the order of the switch ids (the
    /// order `ImportFastqOptions.switchOptionArguments` writes).
    public static func recipeSwitchArguments(_ options: [String: Bool]) -> [String] {
        options.sorted { $0.key < $1.key }.map { ($0.value ? "--" : "--no-") + RecipeSwitch.optionName(for: $0.key) }
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

    /// The Operations row's line for a notice of `import fastq`. The Import
    /// FASTQ sheet logs its grouping's notices with it too, so a notice reads
    /// the same whichever of the two logs it.
    nonisolated static func noticeLine(sample: String, message: String) -> String {
        FASTQImportEventStream.noticeLine(sample: sample, message: message)
    }

    // MARK: - Instance: Run

    /// Spawns the CLI and shows its version 2 events on the operation's row.
    ///
    /// Each `progress` event sets the row's detail, and its fraction moves the
    /// bar only forward. Each `log` event is logged at its level, and each line
    /// of standard error, the command's human text, at info. The bundles come
    /// from the `outputs` of `complete`, by the role of their artifacts, and are
    /// handed to `onBundleCreated` once the run has succeeded. A run that fails
    /// fails the row with the message of its `failed` line. After a cancel the
    /// row is left to the caller, which ends it once its own cleanup has run.
    ///
    /// A CLI that printed no `start` line is not a `lungfish-cli` of this
    /// release. An older one prints the private stream S1, which this runner
    /// no longer reads, so the row fails with a message that names the
    /// mismatch (plan decision T5 of Phase 2.7).
    ///
    /// - Parameters:
    ///   - arguments: CLI arguments (from ``buildCLIArguments``).
    ///   - operationID: The ``OperationCenter`` operation ID to update.
    ///   - projectDirectory: The project the import writes into. The bundles
    ///     are named by the CLI, so it is kept for the callers' signature.
    ///   - onBundleCreated: Called with each bundle the import made.
    ///   - onError: Called with the message of a failure or a cancel.
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
                    progress: Self.launchFraction,
                    detail: "Launching import pipeline\u{2026}"
                )
            }
        }
        if Task.isCancelled {
            // A cancel came before the launch, so nothing runs. The caller
            // ends the operation as cancelled.
            logger.info("CLI import cancelled before launch")
            onError("Import cancelled before it started")
            return
        }

        // The run's events reach the row as the CLI writes them. A cancel
        // gives the CLI `cleanupGrace` after SIGTERM to remove its staging
        // folders before ToolProcess sends SIGKILL. A tool the CLI started that
        // keeps the output open after the CLI exits is stopped half a second
        // later, so it cannot hold the import slot.
        let row = OSAllocatedUnfairLock(initialState: RowProgress(fraction: Self.launchFraction))
        do {
            let result = try await transport.run(
                arguments: arguments,
                terminationGracePeriod: Self.cleanupGrace,
                drainGracePeriod: .milliseconds(500),
                isCancelled: { Task.isCancelled },
                onEvent: { event in Self.show(event, on: opID, row: row) }
            )
            for bundle in Self.bundleURLs(in: result) {
                onBundleCreated(bundle)
            }
        } catch let error as CLISubprocessTransport.RunError {
            let sawStart = row.withLock { $0.sawStart }
            guard let failure = Self.failure(for: error, sawStart: sawStart, binaryURL: binaryURL) else {
                // The import completed without making a bundle, as when it
                // skipped every sample. The caller says no bundle was made.
                return
            }
            logger.error("\(failure.message, privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = OperationCenter.shared.fail(
                        id: opID,
                        detail: failure.message,
                        errorMessage: failure.message,
                        errorDetail: failure.detail
                    )
                }
            }
            onError(failure.message)
        } catch {
            // A cancel. The caller ends the operation, once its own cleanup
            // has run, so the row is not ended here first.
            logger.info("CLI import cancelled")
            onError("Import cancelled")
        }
    }

    /// Where the bar stands while the CLI launches. The bar never falls below it.
    static let launchFraction = 0.01

    /// What the row has shown of one run.
    struct RowProgress {
        var fraction: Double
        var sawStart = false
    }

    /// Shows one event on the row. The command gives each event the text and
    /// level the row shows, and the bar only moves forward.
    static func show(_ event: CLIEvent, on id: UUID, row: OSAllocatedUnfairLock<RowProgress>) {
        switch event {
        case .start:
            row.withLock { $0.sawStart = true }
        case let .progress(fraction, message):
            let shown = row.withLock { state -> Double in
                state.fraction = max(state.fraction, fraction)
                return state.fraction
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = OperationCenter.shared.update(id: id, progress: shown, detail: message)
                }
            }
        case let .log(level, message):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    OperationCenter.shared.log(id: id, level: level.importRowLevel, message: message)
                }
            }
        case .output, .complete, .failed:
            break
        }
    }

    /// The bundles a completed import made, read from `outputs` by the role
    /// of their artifacts. A completion without artifacts names bundles only.
    static func bundleURLs(in result: CLISubprocessTransport.Result) -> [URL] {
        let bundles = Set(result.artifacts.filter { $0.role == CLIEventArtifact.Role.bundle }.map(\.path))
        return result.outputs
            .filter { result.artifacts.isEmpty || bundles.contains($0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// What the row and the caller show for a run that did not complete.
    struct Failure: Equatable {
        let message: String
        let detail: String?
    }

    /// The failure of a run, or nil for an import that completed and named no
    /// bundle, as one that skipped every sample does.
    static func failure(for error: CLISubprocessTransport.RunError, sawStart: Bool, binaryURL: URL) -> Failure? {
        switch error {
        case let .failedEvent(message, detail):
            return Failure(message: message, detail: detail)
        case .missingCompletion:
            return sawStart ? nil : mismatch(binaryURL, detail: nil)
        case let .nonZeroExit(status, standardError):
            let text = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            // A clean exit fails only when a child process kept the output
            // open, and the transport ends the text with that reason.
            let message = status == 0
                ? (text.split(separator: "\n").last.map(String.init) ?? "lungfish-cli did not finish its output")
                : "CLI exited with status \(status)"
            let detail = status == 0 ? text : [message, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return sawStart ? Failure(message: message, detail: detail) : mismatch(binaryURL, detail: detail)
        case .cliNotFound:
            return Failure(message: "lungfish-cli binary not found", detail: nil)
        case let .launchFailed(reason):
            return Failure(message: "Failed to launch CLI process: \(reason)", detail: nil)
        }
    }

    /// The failure of a CLI that printed no version 2 event, such as an older
    /// `lungfish-cli` that prints the private stream S1. The message names the
    /// copy, says what is wrong with it and what to do, in plain words.
    static func mismatch(_ binaryURL: URL, detail: String?) -> Failure {
        Failure(
            message: "This copy of lungfish-cli at \(binaryURL.path) is older than the app and cannot report import "
                + "progress. Reinstall Lungfish Genome Explorer.",
            detail: detail
        )
    }

    // MARK: - Instance: Cancel

    /// How long `lungfish-cli` gets after SIGTERM to remove its staging
    /// folders and workspace before it is killed. Inside OperationCenter's
    /// 10 s forced-acknowledge grace period.
    static let cleanupGrace: Duration = .seconds(5)

    /// Terminates the running CLI process tree, if any, or keeps the CLI
    /// from launching when the cancel comes first.
    ///
    /// Deliberately `nonisolated`: it must be callable — and must complete —
    /// even while `run()` is suspended awaiting the process. It goes through
    /// the transport's own cancellation rather than actor-isolated state, so
    /// cancellation never has to wait in line behind the very operation it is
    /// trying to stop. It returns at once. The CLI and its descendants get
    /// SIGTERM, and the CLI has ``cleanupGrace`` to clean up and exit.
    /// ToolProcess then kills whatever is left.
    public nonisolated func cancel() {
        logger.info("Terminating CLI process tree")
        transport.cancel()
    }
}

private extension CLIEventLogLevel {
    /// The level the row logs an event at, the level the command gave it.
    var importRowLevel: OperationLogLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}
