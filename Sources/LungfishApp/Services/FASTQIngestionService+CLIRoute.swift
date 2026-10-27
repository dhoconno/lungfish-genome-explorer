// FASTQIngestionService+CLIRoute.swift - The in-place FASTQ ingestion on lungfish-cli fastq ingest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FASTQIngestionCLIRoute")

/// Why an in-place ingestion has no `lungfish-cli fastq ingest` command.
enum InPlaceIngestionCLIError: LocalizedError, Equatable {
    /// `fastq ingest` takes one file or an R1 and R2 pair. It has no flag for a file that is
    /// interleaved already, and no caller asks for one.
    case interleaved
    /// A paired-end ingestion needs its R2 file.
    case pairedEndWithoutMate

    var errorDescription: String? {
        switch self {
        case .interleaved:
            return "An interleaved file has no lungfish-cli fastq ingest command."
        case .pairedEndWithoutMate:
            return "A paired-end ingestion needs its R2 file."
        }
    }
}

/// The in-place FASTQ ingestion on `lungfish-cli fastq ingest` (Phase 2.10 lane A47 M3, decision C5
/// and the ruling on M3). Copying a FASTQ file into a project runs the command on `CLIReadsRunner`,
/// the L6 family's runner, in the folder of the file. The command clumpifies and compresses the file,
/// writes the metadata sidecar and a record that names the original's digest, and only then removes
/// the original. The app writes nothing after the command exits.
extension FASTQIngestionService {
    // MARK: - The command

    /// The argv after `lungfish-cli` that the in-place ingestion of `url` runs, which its row records
    /// and the runner runs, built once. It deletes the original as the app's route always has. It
    /// states `--binning` with the default of an unknown platform, since it reads no platform, so a record
    /// replays the same whatever the default is later (BIO-BIN). It states `--threads`, because the command
    /// records its thread count only when given, and `--format json`, so the command prints its events.
    nonisolated static func inPlaceIngestionCLIArguments(
        url: URL,
        pairingMode: FASTQIngestionConfig.PairingMode = .singleEnd,
        pairedFile: URL? = nil,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws -> [String] {
        var arguments = ["fastq", "ingest", url.path]
        switch pairingMode {
        case .singleEnd:
            break
        case .pairedEnd:
            guard let pairedFile else { throw InPlaceIngestionCLIError.pairedEndWithoutMate }
            arguments += ["--pair", pairedFile.path]
        case .interleaved:
            throw InPlaceIngestionCLIError.interleaved
        }
        arguments += [
            "--delete-originals", "--binning", IngestionPlatform.defaultQualityBinning(for: .unknown).rawValue,
            "--threads", String(max(1, threads)), "--format", "json",
        ]
        return arguments
    }

    // MARK: - The route

    /// Registers the in-place ingestion row of `url` and runs `fastq ingest` for it on `runner`.
    /// Returns the row's start result, or nil when the pairing has no command, which no caller asks
    /// for. The row keeps today's title and first detail, and its Cancel stops the waiting task and
    /// the command (`ADDING-AN-OPERATION.md`, Cancel).
    @discardableResult
    static func startInPlaceIngestionThroughCLI(
        url: URL,
        pairingMode: FASTQIngestionConfig.PairingMode = .singleEnd,
        pairedFile: URL? = nil,
        routeContext: OperationRouteContext?,
        runner: CLIReadsRunner = CLIReadsRunner()
    ) -> OperationStartResult? {
        let arguments: [String]
        do {
            arguments = try inPlaceIngestionCLIArguments(url: url, pairingMode: pairingMode, pairedFile: pairedFile)
        } catch {
            logger.error("Ingestion of \(url.lastPathComponent) did not start: \(error.localizedDescription)")
            return nil
        }
        return beginInPlaceIngestionOperation(
            url: url,
            routeContext: routeContext,
            cliArguments: arguments
        ) { opID in
            let task = Task.detached {
                await runInPlaceIngestionThroughCLI(arguments: arguments, operationID: opID, runner: runner)
            }
            OperationCenter.shared.setCancelCallback(for: opID) {
                task.cancel()
                runner.cancel()
            }
        }
    }

    /// Runs `arguments` for the row `opID` and ends the row. The route holds an import slot around the
    /// run, as the bundle import does, so five files copied in together start one clumpify at a time.
    /// The slot stays out of `CLIReadsRunner`, which `map` and `assemble` share. The row shows
    /// "Waiting for available import slot" first, as it always has, and a cancel of a waiting row
    /// launches nothing. The `start` line reaches the row as a log, so it keeps the first detail
    /// `Preparing...`. The command wrote the output, the sidecar and the record before it exited, so
    /// the row only completes with the command's closing words.
    nonisolated static func runInPlaceIngestionThroughCLI(
        arguments: [String],
        operationID opID: UUID,
        runner: CLIReadsRunner
    ) async {
        // Each row change hops to the main actor and waits for it, so the end of the row never races
        // the events the bridge handed over before it (`concurrency-hatches` stays flat).
        await MainActor.run {
            _ = OperationCenter.shared.updateWithLog(
                id: opID,
                progress: 0,
                detail: "Waiting for available import slot\u{2026}"
            )
        }
        do {
            let completion = try await withImportSlot {
                try await runner.runEvents(arguments: arguments, operationID: opID, startAsLog: true)
            }
            let detail = completion.message ?? "Clumpified and compressed"
            await OperationCenterCLIBridge.completeOperation(opID, detail: detail, bundleURLs: [])
        } catch is CancellationError {
            await MainActor.run {
                _ = OperationCenter.shared.acknowledgeCancellation(id: opID, detail: "Cancelled")
            }
        } catch {
            logger.error("Ingestion failed: \(error)")
            // The row takes the user-facing message and keeps the raw text for diagnostics.
            let message = error.localizedDescription
            let raw = "\(error)"
            await MainActor.run {
                _ = OperationCenter.shared.fail(id: opID, detail: message, errorMessage: message, errorDetail: raw)
            }
        }
    }
}
