// ImportCommand+NaoMgsNvd.swift - The async run, cancel and row words that import nao-mgs and import nvd share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import Synchronization

/// The run of `import nao-mgs` and `import nvd`, which the Import Center runs for its NAO-MGS and NVD rows (Phase
/// 2.12 lane 12.05, on the recipe of lane 12.04).
///
/// `ClassifierResultImportRun.perform` runs a blocking import on a thread of its own. The NAO-MGS and NVD services
/// are `async`, and they sit in work that does not look for a cancel (a source folder's hash, a database merge, a
/// samtools run), so a cancel of their task alone could take longer than the app's grace. ``performAsync(input:outputDirectory:_:)``
/// runs the service as a task of its own, hands its result to a thread that SIGTERM releases at once, and ends a
/// cancelled run as `perform` does. It removes the folders this process's service began (the result folder, or the
/// hidden staging folder of an NVD bundle, both named by `ImportResultFolderLedger`) and no other, ends the tools the
/// import started, records the run as cancelled in the project and exits 125.
extension ClassifierResultImportRun {
    /// Runs `work`, an async import, with its progress as events, and returns what it imported.
    ///
    /// - Throws: The exit code 125 after a cancel, else the import's error once the run told why it stopped.
    func performAsync<Imported: Sendable>(
        input inputURL: URL,
        outputDirectory: URL,
        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double, String) -> Void) async throws -> Imported
    ) async throws -> Imported {
        let startedAt = Date()
        let ledgerStart = ImportResultFolderLedger.count
        let emitter = emitter
        let gate = ImportWorkerGate()
        let outcome = await ImportCancellation.run {
            try await ImportCancellation.blocking {
                defer { gate.workerEnded() }
                return try Self.waitForTask {
                    try await work { fraction, message in
                        gate.parkIfCancelled()
                        emitter.emitProgress(max(0.0, min(1.0, fraction)), message: message)
                    }
                }
            }
        }
        switch outcome {
        case .success(let imported):
            return imported
        case .failure(let error) where error is CancellationError:
            // The import stops at its next progress report, or the wait ends after two seconds, so it writes nothing
            // more while the run removes what it began. A folder that a write still holds open is removed again until
            // it is gone, inside the app's grace.
            gate.cancel()
            gate.waitUntilStill(atMost: .seconds(2))
            await Self.endTools()
            for url in ImportResultFolderLedger.createdSince(ledgerStart) {
                for _ in 0..<20 where FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                    if FileManager.default.fileExists(atPath: url.path) { try? await Task.sleep(for: .milliseconds(50)) }
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

    /// Runs `body` as a task of its own and blocks the calling thread, which is not one of the cooperative pool's,
    /// until it ends.
    private static func waitForTask<Imported: Sendable>(_ body: @escaping @Sendable () async throws -> Imported) throws -> Imported {
        let box = TaskOutcome<Imported>()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.set(.success(try await body()))
            } catch {
                box.set(.failure(error))
            }
            finished.signal()
        }
        finished.wait()
        return try box.take().get()
    }

    /// Ends the processes this command started, such as the samtools runs of an import, so none outlives the
    /// command (X14). They get SIGTERM, and SIGKILL after half a second.
    private static func endTools() async {
        let tools = ProcessTreeTerminator.descendantProcessIDs(of: getpid())
        guard !tools.isEmpty else { return }
        for pid in tools { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, tools.contains(where: { ProcessTreeTerminator.processExists(pid: $0) }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        for pid in tools where ProcessTreeTerminator.processExists(pid: pid) { kill(pid, SIGKILL) }
    }
}

/// How a task ended, handed from the task to the thread that waits for it.
private final class TaskOutcome<Imported: Sendable>: Sendable {
    private let result = Mutex<Result<Imported, any Error>?>(nil)

    func set(_ outcome: Result<Imported, any Error>) {
        result.withLock { $0 = outcome }
    }

    func take() -> Result<Imported, any Error> {
        result.withLock { $0 } ?? .failure(CancellationError())
    }
}

/// The words the app's NAO-MGS and NVD rows complete with, which the import helper printed before the rows ran
/// these commands (Phase 2.12 lane 12.05). They stay word for word.
enum NaoMgsNvdImportWords {
    static func naoMgs(_ result: NaoMgsImportResult) -> String {
        "Imported NAO-MGS result: \(ClassifierResultImportWords.groupedNumber(result.totalHitReads)) reads, \(result.taxonCount) taxa"
    }

    static func nvd(_ result: NvdImportResult) -> String {
        "Imported NVD result: \(ClassifierResultImportWords.groupedNumber(result.hitCount)) hits, \(result.sampleCount) samples"
    }
}
