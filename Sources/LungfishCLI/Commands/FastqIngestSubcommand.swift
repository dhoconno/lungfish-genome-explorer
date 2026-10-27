// FastqIngestSubcommand.swift - `lungfish-cli fastq ingest`, the in-place FASTQ ingest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Clumpifies and compresses a FASTQ file in its own folder. This is the run the app makes when a
/// FASTQ file is copied into a project, as a command (Phase 2.10 lane A47, finding L6).
///
/// It runs the same `FASTQIngestionPipeline` as `debug fastq-ingest`, with three differences
/// that matter because the run can delete the user's original file.
///
/// - The pipeline builds its output in a staging folder, under the project's `.tmp` folder when the
///   input sits in a project, else in the system temp folder when that folder is on the input's disk,
///   else in a hidden folder beside the input, and never deletes. The
///   output is synced and renamed into place only when it is whole, so a cancel or a failure
///   leaves the original in place and no half-written output.
/// - The metadata sidecar is written, as the app's run does.
/// - The record holds the SHA-256 of each original and is written before the original goes. The
///   order is write, sync, rename, sidecar, record, then delete (``FastqIngestRun``).
///
/// SIGTERM, which the window's Cancel sends, cancels the run (plan decision C5).
struct FastqIngestSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Clumpify and compress a FASTQ file in place and write its metadata sidecar",
        discussion: """
            Runs the FASTQ ingestion pipeline that the app runs when a FASTQ file is
            copied into a project. The processed file is a .fastq.gz in the folder of
            the input, named for the input without its extension and its _R1, _R2, _1
            or _2 suffix. It is built in a hidden folder, under the project's .tmp
            folder when the input sits in a project and beside the input otherwise,
            and moved into place only when it is whole.

            The command then writes the FASTQ metadata sidecar and a provenance record
            that names each original file with its SHA-256. Only after that does
            --delete-originals remove the original files. A cancel (SIGTERM) or a
            failure leaves the originals in place.

            The command reads no platform, so it bins quality scores with the default of
            an unknown platform unless --binning names a scheme. fiveStep keeps every
            Q10, Q20 and Q30 count. Binning is lossy. With --format json the command
            prints progress as events.

            Examples:
              lungfish-cli fastq ingest ./SRR1770413_1.fastq.gz --delete-originals
              lungfish-cli fastq ingest ./R1.fastq.gz --pair ./R2.fastq.gz --format json
            """
    )

    @Argument(help: "Input FASTQ file (R1 for paired-end)")
    var input: String

    @Option(name: .customLong("pair"), help: "Optional R2 FASTQ file for paired-end mode")
    var pair: String?

    @Option(name: .customLong("binning"), help: "Quality binning: fiveStep, illumina4 (to replay older imports), eightLevel or none")
    var binning: QualityBinningScheme = IngestionPlatform.defaultQualityBinning(for: .unknown)

    @Flag(name: .customLong("skip-clumpify"), help: "Skip read clumpification step")
    var skipClumpify: Bool = false

    @Flag(
        name: .customLong("delete-originals"),
        help: "Delete the original FASTQ file(s) once the output, its sidecar and its record are written"
    )
    var deleteOriginals: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    /// Runs the ingest so that SIGTERM cancels it instead of ending the command, as the app's
    /// Cancel does (plan decision C5). A cancel before the output is published stops the tool,
    /// removes the staging folder, writes a `cancelled` record and exits 125, with every original
    /// as it was. The command listens before the task starts, so an early SIGTERM cancels the
    /// task once it exists, and a second SIGTERM ends the command at once. A SIGTERM that comes
    /// after the output is published does not turn a finished ingest into a cancelled one.
    func run() async throws {
        let pendingCancel = PendingTaskCancel<(any Error)?>()
        let termination = SIGTERMCancellation(secondSignalEndsProcess: true) {
            pendingCancel.cancel()
            FileHandle.standardError.write(Data("Cancelling the ingest.\n".utf8))
        }
        defer { termination.end() }
        let task = Task { () -> (any Error)? in
            do {
                try await self.execute(emit: { printEventLine($0) }, signalled: { SIGTERMCancellation.signalCaught })
                return nil
            } catch {
                return error
            }
        }
        pendingCancel.attach(task)
        guard let error = await task.value else { return }
        if error is CancellationError {
            FileHandle.standardError.write(Data("Ingest cancelled. The original files are as they were.\n".utf8))
            throw CLIExitCode.cancelled.exitCode
        }
        throw error
    }

    /// The run, with each event line handed to `emit`. `signalled` says whether the command was sent
    /// SIGTERM, which the command's `run()` reads from its own scope. A caller with no scope, such as a
    /// test, passes nothing, so a SIGTERM an earlier instance caught cannot turn a failure into a cancel.
    func execute(emit: @escaping (String) -> Void, signalled: @escaping @Sendable () -> Bool = { false }) async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
        let clock = ProvenanceRunClock()
        let inputs = inputURLs()
        events.emitStart("Ingesting \(FASTQIngestionPipeline.deriveBaseName(from: inputs[0]))...")
        do {
            let outcome = try await FastqIngestRun(
                inputs: inputs,
                options: runOptions(),
                command: replayArgv(),
                parameters: provenanceParameters(inputs: inputs),
                defaults: Self.provenanceDefaults,
                events: events,
                clock: clock,
                signalled: signalled
            ).run()
            events.emitComplete(output: outcome.output.path, message: outcome.message)
            if !globalOptions.quiet {
                printHumanLine(outcome.message, eventsOn: eventsOn)
                printHumanLine("output: \(outcome.output.path)", eventsOn: eventsOn)
            }
        } catch is CancellationError {
            // A cancel is not a failure. The app's transport reports it from the exit status.
            await recordCancelled(inputs: inputs, clock: clock)
            throw CancellationError()
        } catch {
            events.emitFailed(CLIFailureWords.describe(error))
            throw error
        }
    }

    // MARK: - Arguments

    func inputURLs() -> [URL] {
        ([input] + (pair.map { [$0] } ?? [])).map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// The pairing a lone input is ingested with. It is interleaved when the input's metadata sidecar records
    /// pairs alone, as `extract taxa-collection` writes it beside a file of pairs, and single-end otherwise. A lone
    /// file is not set to single-end against its recorded layout, the rule `FASTQBatchImporter` follows.
    static func pairingOfALoneFile(_ input: URL) -> FASTQIngestionConfig.PairingMode {
        FASTQMetadataStore.load(for: input)?.ingestion?.pairingMode == .interleaved ? .interleaved : .singleEnd
    }

    func runOptions() -> FastqIngestRun.Options {
        FastqIngestRun.Options(
            pairingMode: pair == nil ? Self.pairingOfALoneFile(inputURLs()[0]) : .pairedEnd,
            binning: binning,
            skipClumpify: skipClumpify,
            deleteOriginals: deleteOriginals,
            threads: max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount)
        )
    }

    /// The argv the record names: the words the command was started with, in a fixed order.
    func replayArgv() -> [String] {
        var argv = [CLICommandIdentity.executableName, "fastq", "ingest", input]
        if let pair {
            argv += ["--pair", pair]
        }
        // The binning is always named, so the record replays the same whatever the default is (lane C2-BINNING).
        argv += ["--binning", binning.rawValue]
        if skipClumpify {
            argv.append("--skip-clumpify")
        }
        if deleteOriginals {
            argv.append("--delete-originals")
        }
        if let threads = globalOptions.threads {
            argv += ["--threads", String(threads)]
        }
        if globalOptions.quiet {
            argv.append("--quiet")
        }
        if globalOptions.outputFormat == .json {
            argv += ["--format", "json"]
        }
        return argv
    }

    // MARK: - Record

    func provenanceParameters(inputs: [URL]) -> [String: ParameterValue] {
        [
            "input": .file(inputs[0]),
            "pair": inputs.dropFirst().first.map(ParameterValue.file) ?? .null,
            "pairingMode": .string(runOptions().pairingMode.rawValue),
            "binning": .string(binning.rawValue),
            "skipClumpify": .boolean(skipClumpify),
            "deleteOriginals": .boolean(deleteOriginals),
            "threads": .integer(runOptions().threads),
            "quiet": .boolean(globalOptions.quiet),
        ]
    }

    static var provenanceDefaults: [String: ParameterValue] {
        [
            "pair": .null,
            "pairingMode": .string(FASTQIngestionConfig.PairingMode.singleEnd.rawValue),
            "binning": .string(IngestionPlatform.defaultQualityBinning(for: .unknown).rawValue),
            "skipClumpify": .boolean(false),
            "deleteOriginals": .boolean(false),
            "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
            "quiet": .boolean(false),
        ]
    }

    /// Records the cancel in the input's folder, where a completed run records itself. A record
    /// that stands there already is the folder's history, such as a bundle's import record or the
    /// record an input carries, so a cancelled run writes nothing and the folder stays as it was.
    /// A merge would point the old outputs at a file that was never published. The lookup is the
    /// one the completed run merges into (ruling on A47 M3, section 1), and a record that cannot be
    /// read counts as standing. The write never checks cancellation, so it finishes inside the
    /// grace the app gives the command before SIGKILL.
    private func recordCancelled(inputs: [URL], clock: ProvenanceRunClock) async {
        let folder = inputs[0].deletingLastPathComponent()
        let standing: Bool
        do {
            standing = try InPlaceIngestionProvenance.existingInPlaceIngestionProvenance(
                outputDirectory: folder,
                inputFiles: inputs
            ) != nil
        } catch {
            standing = true
        }
        guard !standing else {
            FileHandle.standardError.write(Data(
                "\(folder.lastPathComponent) holds a record already, so the cancelled run adds none.\n".utf8
            ))
            return
        }
        do {
            try await CLIProvenanceSupport.recordSingleStepRun(
                name: FastqIngestRun.recordName,
                parameters: provenanceParameters(inputs: inputs),
                defaults: Self.provenanceDefaults,
                toolName: "FASTQIngestionPipeline",
                toolVersion: WorkflowRun.currentAppVersion,
                command: replayArgv(),
                inputs: [],
                outputs: [],
                exitCode: CLIExitCode.cancelled.rawValue,
                wallTime: clock.now.timeIntervalSince(clock.startedAt),
                stderr: nil,
                status: .cancelled,
                outputDirectory: folder
            )
        } catch {
            FileHandle.standardError.write(Data("Could not record the cancel: \(error.localizedDescription)\n".utf8))
        }
    }
}
