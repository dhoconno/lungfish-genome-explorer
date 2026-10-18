// CLIBlastSubmitRunner.swift - Runs `lungfish-cli blast submit` through CLISubprocessTransport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import Synchronization

/// What a viewer's BLAST action hands `blast submit` (Phase 2.11 lane A65, plan decision C1). The
/// viewer has written its reads or contigs under `<project>/.tmp/` through `DurableReplace`, and the
/// leaf copies them into `outputURL`, so the record names a query that outlives the `.tmp` sweep.
struct BlastSubmitRequest: Sendable, Equatable {
    var queryURL: URL
    var outputURL: URL
    var label: String
    var taxId: Int?
    var contig: String?
    var sourceResultURL: URL?
    var sample: String?
    var subsampleCount: Int?
    var subsampleSeed: UInt64?
    var entrezQuery: String?
    var acceptedTaxIds: [Int] = []
    var acceptedNames: [String] = []
    var relatedTaxIds: [Int] = []
    var relatedNames: [String] = []
    /// The NCBI database, sent as `--database` only when set, so a request with none searches the leaf's
    /// default `core_nt` (2.12 lane 12.10, BIO 3).
    var database: String? = nil
}

/// The files a completed `blast submit` names, its record first.
struct CLIBlastSubmitResult: Sendable, Equatable {
    let recordPath: String
    let queryPath: String?
    let message: String?
}

enum CLIBlastSubmitRunnerError: Error, LocalizedError, Equatable {
    case cliBinaryNotFound
    case processLaunchFailed(String)
    case processExited(status: Int32, stderr: String)
    case runFailed(message: String)
    case missingCompletion
    case queryDigestMismatch(expected: String, found: String)

    var errorDescription: String? {
        switch self {
        case .cliBinaryNotFound: return "lungfish-cli binary not found"
        case .processLaunchFailed(let detail): return "Failed to launch lungfish-cli: \(detail)"
        case .processExited(let status, let stderr):
            return stderr.isEmpty ? "lungfish-cli exited with status \(status)" : "lungfish-cli exited with status \(status): \(stderr)"
        case .runFailed(let message): return message
        case .missingCompletion: return "lungfish-cli finished without reporting the BLAST result."
        case .queryDigestMismatch(let expected, let found):
            return "The BLAST record names query \(found), not the query \(expected) the viewer wrote."
        }
    }
}

/// Runs the leaf on the shape of the 2.10 runners (decision C5): a plain struct over the transport,
/// the 6-second `operationGrace` between SIGTERM and SIGKILL, the 500 ms `operationDrain`, and a
/// `cancel()` that returns at once from any thread instead of queueing behind `run()`.
struct CLIBlastSubmitRunner {
    private let transport: CLISubprocessTransport
    private let cancellationRequested = BlastSubmitCancelFlag()

    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// The argv of `request`. The query travels as a path, never as text, and each lineage value is
    /// an option of its own, present only when the viewer has it.
    static func arguments(for request: BlastSubmitRequest) -> [String] {
        var arguments = [
            "blast", "submit",
            "--query", request.queryURL.path,
            "--output", request.outputURL.path,
            "--name", request.label,
        ]
        if let taxId = request.taxId { arguments += ["--taxid", String(taxId)] }
        if let contig = request.contig { arguments += ["--contig", contig] }
        if let source = request.sourceResultURL { arguments += ["--source-result", source.path] }
        if let sample = request.sample { arguments += ["--sample", sample] }
        if let count = request.subsampleCount { arguments += ["--subsample-count", String(count)] }
        if let seed = request.subsampleSeed { arguments += ["--subsample-seed", String(seed)] }
        if let entrez = request.entrezQuery { arguments += ["--entrez-query", entrez] }
        for taxId in request.acceptedTaxIds.sorted() { arguments += ["--accepted-taxid", String(taxId)] }
        for name in request.acceptedNames { arguments += ["--accepted-name", name] }
        for taxId in request.relatedTaxIds.sorted() { arguments += ["--related-taxid", String(taxId)] }
        for name in request.relatedNames { arguments += ["--related-name", name] }
        if let database = request.database { arguments += ["--database", database] }
        return arguments + ["--format", "json", "--no-progress"]
    }

    /// Runs `arguments`, handing each event to `onEvent`, and returns the files of the completion.
    func run(
        arguments: [String],
        onEvent: @escaping @Sendable (CLIEvent) -> Void = { _ in }
    ) async throws -> CLIBlastSubmitResult {
        do {
            let result = try await transport.run(
                arguments: arguments,
                terminationGracePeriod: CLIProcessLauncher.operationGrace,
                drainGracePeriod: CLIProcessLauncher.operationDrain,
                isCancelled: { [cancellationRequested] in cancellationRequested.isSet },
                onEvent: onEvent
            )
            guard let record = result.outputs.first else { throw CLIBlastSubmitRunnerError.missingCompletion }
            return CLIBlastSubmitResult(
                recordPath: record,
                queryPath: result.outputs.dropFirst().first,
                message: result.message
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CLISubprocessTransport.RunError {
            switch error {
            case .nonZeroExit(let status, let stderr):
                throw CLIBlastSubmitRunnerError.processExited(status: status, stderr: stderr)
            case .launchFailed(let message):
                throw CLIBlastSubmitRunnerError.processLaunchFailed(message)
            case .cliNotFound:
                throw CLIBlastSubmitRunnerError.cliBinaryNotFound
            case .missingCompletion:
                throw CLIBlastSubmitRunnerError.missingCompletion
            case .failedEvent(let message, _):
                throw CLIBlastSubmitRunnerError.runFailed(message: message)
            }
        }
    }

    /// Returns at once. The transport sends SIGTERM to the leaf's group and SIGKILL after the grace.
    func cancel() {
        cancellationRequested.set()
        transport.cancel()
    }
}

/// A flag set from any thread and read from the transport's poll.
private final class BlastSubmitCancelFlag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}
