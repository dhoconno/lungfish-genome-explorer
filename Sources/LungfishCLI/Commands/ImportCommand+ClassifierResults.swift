// ImportCommand+ClassifierResults.swift - The events, cancel and row words that import kraken2, esviritu and taxtriage share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import Synchronization

/// One run of `import kraken2`, `import esviritu` or `import taxtriage`, which the Import Center runs for its
/// classifier result rows (Phase 2.12 lane 12.04, the recipe `import bam` got in 2.11 lane A63).
///
/// With `--format json` the run prints `start`, the import's `progress` lines and `complete`, whose `outputs`
/// name the result folder and whose message holds the words the row completes with, or `failed` with why it
/// stopped. Its summary then goes to standard error through `printHumanLine`. Without the option the run prints
/// the text it printed before.
///
/// The import runs on a thread of its own inside ``ImportCancellation/run(_:)``. SIGTERM, the app's Cancel,
/// ends the wait at once. The run removes the result folder it began, records itself as cancelled in the
/// project, prints the `failed` line and exits 125 inside the app's grace (decision S7). The import's thread
/// cannot be interrupted, and it ends when the command exits.
struct ClassifierResultImportRun {
    let kind: MetagenomicsImportKind
    let formatter: TerminalFormatter
    let emitter: ImportCLIEventEmitter
    let eventsOn: Bool
    private let startedAt = Date()

    /// Prints the `start` line when events are on.
    init(kind: MetagenomicsImportKind, globalOptions: GlobalOptions) {
        self.kind = kind
        formatter = TerminalFormatter(useColors: globalOptions.useColors)
        eventsOn = globalOptions.outputFormat == .json
        emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
        emitter.emitStart(kind: "\(kind.importCommandToken)-result")
    }

    /// One line of the summary, on standard output, or on standard error while events are on.
    func say(_ line: String) {
        printHumanLine(line, eventsOn: eventsOn)
    }

    /// Why the run stopped, as the `failed` line while events are on, else as the error line it printed before.
    func refuse(_ message: String) {
        if eventsOn {
            emitter.emitFailed(message)
        } else {
            print(formatter.error(message))
        }
    }

    /// Runs `work`, the service's import, with its progress as events, and returns what it imported.
    ///
    /// - Throws: The exit code 125 after a cancel, else the import's error once the run told why it stopped.
    func perform<Imported: Sendable>(
        input inputURL: URL,
        outputDirectory: URL,
        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double, String) -> Void) throws -> Imported
    ) async throws -> Imported {
        let foldersBefore = resultFolders(in: outputDirectory)
        let emitter = emitter
        let gate = ImportWorkerGate()
        let outcome = await ImportCancellation.run {
            try await ImportCancellation.blocking {
                defer { gate.workerEnded() }
                return try work { fraction, message in
                    gate.parkIfCancelled()
                    emitter.emitProgress(max(0.0, min(1.0, fraction)), message: message)
                }
            }
        }
        switch outcome {
        case .success(let imported):
            return imported
        case .failure(let error) where error is CancellationError:
            // The import's thread stops at its next progress report, or the wait ends after two seconds, so it
            // writes nothing more while the run removes the folder it began. A folder that a write still holds
            // open is removed again until it is gone, inside the app's grace.
            gate.cancel()
            gate.waitUntilStill(atMost: .seconds(2))
            for folder in resultFolders(in: outputDirectory).subtracting(foldersBefore) {
                let url = outputDirectory.appendingPathComponent(folder, isDirectory: true)
                for _ in 0..<20 where FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                    if FileManager.default.fileExists(atPath: url.path) { usleep(50_000) }
                }
            }
            throw await ImportCancellation.finish(
                emitter: emitter,
                command: "import \(kind.importCommandToken)",
                parameters: ["input": .file(inputURL), "outputDirectory": .file(outputDirectory)],
                recordDirectory: ProjectTempDirectory.findProjectRoot(outputDirectory) ?? outputDirectory,
                startedAt: startedAt
            )
        case .failure(let error):
            refuse(error.localizedDescription)
            throw error
        }
    }

    /// The `complete` line. `outputs` names the result folder, and the message is the row's words. The event has
    /// the same form as the completion of an alignment attached to a bundle, a path and a message.
    func complete(_ resultDirectory: URL, message: String) {
        emitter.emitComplete(attachedTo: resultDirectory, message: message)
    }

    /// The folders in `folder` whose name starts as this kind's result folders do.
    private func resultFolders(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasPrefix(kind.directoryPrefix) })
    }
}

/// Stops an import's thread at its next progress report once the run was cancelled. The thread then waits until
/// the command exits, so it adds nothing to the folder the run removes.
final class ImportWorkerGate: Sendable {
    private struct State {
        var cancelled = false
        var still = false
    }

    private let state = Mutex(State())
    /// Never signalled. A parked thread ends with the process.
    private let parking = DispatchSemaphore(value: 0)

    /// Called by the import's thread at each progress report.
    func parkIfCancelled() {
        let park = state.withLock { state -> Bool in
            if state.cancelled { state.still = true }
            return state.cancelled
        }
        if park { parking.wait() }
    }

    /// Called by the import's thread when the import returned or threw.
    func workerEnded() {
        state.withLock { $0.still = true }
    }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    /// Waits until the import's thread parked or ended, at most `limit`.
    func waitUntilStill(atMost limit: Duration) {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !state.withLock({ $0.still }), ContinuousClock.now < deadline {
            usleep(10_000)
        }
    }
}

/// The words the app's classifier result row completes with, which its import helper printed before the row ran
/// these commands (Phase 2.12 lane 12.04). They stay word for word.
enum ClassifierResultImportWords {
    static func kraken2(_ result: Kraken2ImportResult) -> String {
        "Imported Kraken2 result: \(groupedNumber(result.totalReads)) reads, \(result.speciesCount) species"
    }

    static func esViritu(_ result: EsVirituImportResult) -> String {
        "Imported EsViritu result: \(result.importedFileCount) files, \(result.virusCount) detections"
    }

    static func taxTriage(_ result: TaxTriageImportResult) -> String {
        "Imported TaxTriage result: \(result.importedFileCount) files"
    }

    /// A count with a comma between groups of digits in every locale, as the helper wrote it.
    static func groupedNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
