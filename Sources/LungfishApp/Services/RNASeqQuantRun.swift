// RNASeqQuantRun.swift - The quantify row of the FASTQ operations dialog, run through lungfish-cli rnaseq quant
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import os

/// What the quantify pane asks for, in the words of `lungfish-cli rnaseq quant`.
///
/// The dialog never counts a read. It builds this request, runs the CLI on `argv` and shows what the CLI wrote. The CLI
/// reads each FASTQ bundle through its own `ReadSetResolver`, which writes a virtual bundle's reads to the run's work
/// folder before salmon starts (`SalmonQuantRoute.swift:140`), so the argv names the bundle folders and never a
/// `preview.fastq` (`analysis-surface-checklist.md:25`).
struct RNASeqQuantRunRequest: Sendable, Equatable {
    enum Decoys: String, Sendable, Equatable {
        case genome
        case none
    }

    var bundleURLs: [URL]
    var projectURL: URL
    var setID: String
    var k: Int
    var decoys: Decoys
    var trim: Bool
    var polyGTrimming: Bool

    /// The argv after the binary name. This one array runs, shows in the Operations row and parses back through the
    /// real subcommand. Every setting is named, so the recorded command keeps its meaning if a default changes.
    var argv: [String] {
        var arguments = ["rnaseq", "quant"] + bundleURLs.map(\.path)
        arguments += ["--project", projectURL.path, "--set", setID, "--k", String(k), "--decoys", decoys.rawValue]
        if trim {
            arguments += ["--trim", "--poly-g-trimming", polyGTrimming ? "on" : "off"]
        }
        arguments += ["--format", "json"]
        return arguments
    }

    /// The shell-quoted command the Operations row shows, built from the argv that runs.
    var cliCommand: String {
        OperationCenter.buildCLICommand(subcommand: "rnaseq quant", args: Array(argv.dropFirst(2)))
    }
}

/// What the CLI reports when a quant ends well, read from its `--format json` summary.
struct RNASeqQuantRunOutcome: Sendable, Equatable {
    let resultURL: URL
    let samples: [String]
}

enum RNASeqQuantRunError: Error, Equatable, LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case cancelled
    case failed(status: Int32, message: String)
    case unreadableSummary

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The lungfish-cli command was not found next to the app."
        case .launchFailed(let reason):
            return "The quantification could not start. \(reason)"
        case .cancelled:
            return "The quantification was cancelled. No result was written."
        case .failed(_, let message):
            return message
        case .unreadableSummary:
            return "The quantification ended, but its summary could not be read."
        }
    }
}

/// Runs the argv of a quantify request and reads its summary. A stand-in conforms in tests.
protocol RNASeqQuantCommandRunning: Sendable {
    func run(
        argv: [String],
        cancellation: CLIRunCancellation,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> RNASeqQuantRunOutcome
}

/// Runs `lungfish-cli` on ``CLIProcessLauncher``. A cancel signals the CLI through `cancellation`, which gives it SIGTERM
/// and ``terminationGracePeriod``, and the CLI's own cancel stops salmon and removes its work folder.
struct CLIRNASeqQuantRunner: RNASeqQuantCommandRunning {
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace

    private let cliURLProvider: @Sendable () -> URL?
    private let environmentAdditions: [String: String]

    /// `environmentAdditions` are laid over the app's subprocess environment, empty in the app. A test names the storage
    /// folder and the tool folder of its own root there, so the CLI finds a set the row never writes a flag for.
    init(
        cliURLProvider: @escaping @Sendable () -> URL? = { LungfishCLIRunner.findCLI() },
        environmentAdditions: [String: String] = [:]
    ) {
        self.cliURLProvider = cliURLProvider
        self.environmentAdditions = environmentAdditions
    }

    func run(
        argv: [String],
        cancellation: CLIRunCancellation,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> RNASeqQuantRunOutcome {
        guard let cliURL = cliURLProvider() else { throw RNASeqQuantRunError.cliNotFound }
        let spec = CLIProcessLauncher.spec(
            executableURL: cliURL,
            arguments: argv,
            terminationGracePeriod: Self.terminationGracePeriod,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            environmentAdditions: environmentAdditions
        )
        let summary = OSAllocatedUnfairLock<[String]>(initialState: [])
        let outcome = await CLIProcessLauncher.run(
            spec,
            cancellation: cancellation,
            onStdoutLine: { line in summary.withLock { $0.append(line) } },
            onStderrLine: { log($0) }
        )
        switch outcome {
        case .launchFailed(let reason):
            throw RNASeqQuantRunError.launchFailed(reason)
        case .cancelled:
            throw RNASeqQuantRunError.cancelled
        case .exited(let exit):
            if Task.isCancelled { throw RNASeqQuantRunError.cancelled }
            guard exit.status == 0 else {
                let message = "\(exit.stderr)".trimmingCharacters(in: .whitespacesAndNewlines)
                throw RNASeqQuantRunError.failed(
                    status: Int32(exit.status),
                    message: message.isEmpty ? "The quantification stopped with status \(exit.status)." : message
                )
            }
            return try Self.outcome(fromStdout: summary.withLock { $0 })
        }
    }

    /// The last JSON object line of the CLI's standard output, whose `result` and `samples` the summary holds.
    static func outcome(fromStdout lines: [String]) throws -> RNASeqQuantRunOutcome {
        guard let line = lines.last(where: { $0.hasPrefix("{") }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let result = object["result"] as? String, !result.isEmpty
        else { throw RNASeqQuantRunError.unreadableSummary }
        return RNASeqQuantRunOutcome(
            resultURL: URL(fileURLWithPath: result, isDirectory: true),
            samples: (object["samples"] as? [String]) ?? []
        )
    }
}

/// Registers the run with `begin`, runs the CLI and settles the row. The route holds no count and no result path of its
/// own. It shows what the CLI printed.
@MainActor
enum RNASeqQuantRoute {
    /// Returns the task that ends with the row settled, or `nil` when `begin` refused the run and nothing launched.
    @discardableResult
    static func launch(
        _ request: RNASeqQuantRunRequest,
        operations: any OperationReporting = OperationCenter.shared,
        routeContext: OperationRouteContext? = nil,
        runner: any RNASeqQuantCommandRunning = CLIRNASeqQuantRunner()
    ) -> Task<Void, Never>? {
        let cancellation = CLIRunCancellation()
        let count = request.bundleURLs.count
        let noun = count == 1 ? "sample" : "samples"
        let started = operations.begin(
            title: "Count Reads per Gene",
            detail: "Counting \(count) \(noun) against \(request.setID)",
            operationType: .rnaSeqQuantification,
            targetBundleURL: nil,
            additionalLockedBundleURLs: request.bundleURLs,
            cliCommand: request.cliCommand,
            routeContext: routeContext,
            onCancel: { cancellation.cancel() }
        )
        guard case .started(let id) = started else { return nil }
        _ = operations.update(id: id, progress: 0, detail: "Counting \(count) \(noun) against \(request.setID)")
        // The CLI's lines arrive on a background thread. They reach the row in order on the main actor through one
        // stream, and the row settles only after the stream has drained.
        let (lines, lineSink) = AsyncStream<String>.makeStream()
        let logger = Task { @MainActor in
            for await line in lines { operations.log(id: id, level: .info, message: line) }
        }
        return Task { @MainActor in
            do {
                let outcome: RNASeqQuantRunOutcome
                do {
                    outcome = try await runner.run(argv: request.argv, cancellation: cancellation) { lineSink.yield($0) }
                } catch {
                    lineSink.finish()
                    await logger.value
                    throw error
                }
                lineSink.finish()
                await logger.value
                operations.trackAnalysisOutput(outcome.resultURL, for: id)
                let done = outcome.samples.count
                _ = operations.complete(
                    id: id,
                    detail: "Counted \(done) \(done == 1 ? "sample" : "samples") against \(request.setID)",
                    outputURLs: [outcome.resultURL]
                )
            } catch RNASeqQuantRunError.cancelled {
                _ = operations.acknowledgeCancellation(id: id, detail: "Cancelled. No result was written.")
            } catch {
                operations.log(id: id, level: .error, message: error.localizedDescription)
                _ = operations.fail(id: id, detail: "Counting reads per gene failed", errorMessage: error.localizedDescription)
            }
        }
    }
}
