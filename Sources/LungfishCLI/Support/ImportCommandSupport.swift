// ImportCommandSupport.swift - The event emitter, summaries, destination and cancel that every import leaf shares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os
import Synchronization

/// The version 2 events of the four import commands, `import msa`, `import tree`, `import geneious`
/// and `import application-export`, written through the shared `CLIEventEmitter` and `printEventLine`.
///
/// Before version 2 each pair of commands had a private emitter and event names of its own, which
/// `CLIEventLegacyNames` still reads for an older CLI (decision V13). A warning is a `log` event at
/// level `warning`, so a reader counts them from the events. The completion names the bundle or
/// collection in `outputs`, the one list an app imports from, and holds one typed artifact that
/// describes it. A command with `--format json` prints its summary through `printHumanLine`, which
/// puts the text on standard error while events are on.
///
/// With events off nothing is written as an event, so a person would learn of neither a warning nor a
/// failure. The emitter then writes each warning as a `Warning: <message>` line and the failure as an
/// `Error: <message>` line on standard error, through `printStatusLine`. `--quiet` drops the warnings
/// and keeps the failure.
struct ImportCLIEventEmitter: Sendable {
    private let events: CLIEventEmitter
    private let eventsOn: Bool
    private let quiet: Bool

    init(enabled: Bool, quiet: Bool = false) {
        events = CLIEventEmitter(enabled: enabled) { printEventLine($0) }
        eventsOn = enabled
        self.quiet = quiet
    }

    /// The start line names the kind of what the command imports, such as `phylogenetic-tree`.
    func emitStart(kind: String) {
        events.emitStart("Started \(kind) import via lungfish-cli")
    }

    func emitProgress(_ fraction: Double, message: String) {
        events.emitProgress(fraction, message: message)
    }

    func emitWarning(_ message: String) {
        events.emitLog(.warning, message)
        if !eventsOn, !quiet {
            printStatusLine("Warning: \(message)")
        }
    }

    /// The completion of an import that made a bundle. The artifact is typed by the bundle kind and
    /// names the bundle's own provenance record when the importer wrote one.
    func emitComplete(bundle bundleURL: URL, kind: BundleKindID) {
        let record = bundleURL.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        events.emitComplete(
            outputs: [bundleURL.path],
            artifacts: [CLIEventArtifact(
                kind: kind.rawValue,
                path: bundleURL.path,
                role: "bundle",
                provenancePath: FileManager.default.fileExists(atPath: record.path) ? record.path : nil
            )]
        )
    }

    /// The completion of an import that made a collection folder, with the record it wrote.
    func emitComplete(collection collectionURL: URL, provenanceURL: URL) {
        events.emitComplete(
            outputs: [collectionURL.path],
            artifacts: [CLIEventArtifact(
                kind: "import-collection",
                path: collectionURL.path,
                role: "collection",
                provenancePath: provenanceURL.path
            )]
        )
    }

    /// The completion of an import that added a track to an existing bundle, with the words the row shows.
    func emitComplete(attachedTo bundleURL: URL, message: String) {
        events.emitComplete(outputs: [bundleURL.path], message: message)
    }

    func emitFailed(_ message: String) {
        events.emitFailed(message)
        if !eventsOn {
            printStatusLine("Error: \(message)")
        }
    }
}

/// What a bundle import tells the rest of its command once the importer returned, in values that cross
/// a task boundary.
struct ImportedBundleSummary: Sendable {
    let warnings: [String]
    /// The lines the command prints after `Imported <path>`, such as `Rows: 12`.
    let summaryLines: [String]
}

/// The bundle a bundle import made and what the importer reported.
struct ImportedBundle: Sendable {
    let bundleURL: URL
    let summary: ImportedBundleSummary
}

/// What a collection import tells the rest of its command once the service returned.
struct ImportedCollectionSummary: Sendable {
    let collectionURL: URL
    let provenanceURL: URL
    let warnings: [String]
}

/// The bundle a run would publish, which the run sets once it has chosen the path, so a cancel can remove
/// what the run made. A path that existed before the importer ran is never removed.
final class ImportDestination: Sendable {
    private let state = OSAllocatedUnfairLock<(url: URL, existedBefore: Bool)?>(initialState: nil)

    func set(_ url: URL) {
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        state.withLock { $0 = (url, existedBefore) }
    }

    func removeIfCreatedByThisRun() {
        guard let chosen = state.withLock({ $0 }), !chosen.existedBefore else { return }
        try? FileManager.default.removeItem(at: chosen.url)
    }
}

/// The cancel that the four import commands share (Phase 2.11 lane A63, decision S7).
///
/// The app's Cancel sends the command SIGTERM and gives it `operationGrace` before SIGKILL. A command
/// that scopes ``run(_:)`` around its import turns the signal into a cancel of that import, records the
/// run as cancelled in the project, tells the row with a `failed` event that carries ``message`` and
/// exits 125 through ``finish(emitter:command:parameters:recordDirectory:startedAt:)``. A second SIGTERM
/// ends the process at once.
enum ImportCancellation {
    /// What the command's `failed` event and its record say once the import was cancelled.
    static let message = "Import cancelled. Nothing was published."

    /// Runs `work` as a task that SIGTERM cancels, and returns how it ended. A failure after the signal
    /// was caught is the cancel, whatever error it carries, since a tool that got the same signal can end
    /// first.
    static func run<Success: Sendable>(
        _ work: @escaping @Sendable () async throws -> Success
    ) async -> Result<Success, any Error> {
        let pendingCancel = PendingTaskCancel<Result<Success, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let task = Task { () -> Result<Success, any Error> in
            do {
                return .success(try await work())
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || SIGTERMCancellation.signalCaught
                return .failure(cancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        return outcome
    }

    /// Runs the blocking `work` on a thread of its own and returns its result, or throws
    /// `CancellationError` as soon as the calling task is cancelled, whichever comes first. A cancel does
    /// not stop `work`, which may sit in a read that cannot be interrupted. The command exits right after
    /// the cancel, which ends the thread.
    static func blocking<Success: Sendable>(
        _ work: @escaping @Sendable () throws -> Success
    ) async throws -> Success {
        let handoff = BlockingHandoff<Success>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handoff.start(continuation)
                Thread.detachNewThread {
                    handoff.finish(Result { try work() })
                }
            }
        } onCancel: {
            handoff.cancel()
        }
    }

    /// The end of a cancelled import, which every command shares. It records the run as cancelled in
    /// `recordDirectory`, tells the row with the `failed` event and returns the exit code the command
    /// throws, 125. A record that cannot be written does not hide the cancel.
    static func finish(
        emitter: ImportCLIEventEmitter,
        command: String,
        parameters: [String: ParameterValue],
        recordDirectory: URL,
        startedAt: Date
    ) async -> ExitCode {
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish \(command)",
            parameters: parameters,
            toolName: "lungfish \(command)",
            toolVersion: LungfishCLI.configuration.version,
            command: [CLICommandIdentity.executableName] + Array(CommandLine.arguments.dropFirst()),
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: message,
            status: .cancelled,
            outputDirectory: recordDirectory,
            writeFileSidecars: false
        )
        emitter.emitFailed(message)
        return CLIExitCode.cancelled.exitCode
    }
}

/// Hands the outcome of a blocking call to the task that awaits it, or the cancel of that task,
/// whichever comes first. The continuation resumes once.
private final class BlockingHandoff<Success: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Success, any Error>?
        var cancelRequested = false
        var resumed = false
    }

    private let state = Mutex(State())

    /// Stores the continuation, or resumes it at once when the cancel came first.
    func start(_ continuation: CheckedContinuation<Success, any Error>) {
        let cancelled = state.withLock { state -> Bool in
            if state.cancelRequested {
                state.resumed = true
                return true
            }
            state.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Resumes the task with the result of the call, unless the cancel resumed it first.
    func finish(_ result: Result<Success, any Error>) {
        let continuation = takeContinuation(requestingCancel: false)
        continuation?.resume(with: result)
    }

    /// Resumes the task with a cancel, unless the call finished first.
    func cancel() {
        let continuation = takeContinuation(requestingCancel: true)
        continuation?.resume(throwing: CancellationError())
    }

    private func takeContinuation(requestingCancel: Bool) -> CheckedContinuation<Success, any Error>? {
        state.withLock { state in
            if requestingCancel {
                state.cancelRequested = true
            }
            guard !state.resumed, let continuation = state.continuation else { return nil }
            state.resumed = true
            state.continuation = nil
            return continuation
        }
    }
}
