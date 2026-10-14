// BundleMarkDuplicatesSubcommand.swift - Add duplicate-marked copies of a bundle's alignment tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Mark Duplicates Subcommand

struct BundleMarkDuplicatesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark-duplicates",
        abstract: "Add duplicate-marked copies of a bundle's alignment tracks, keeping the originals",
        discussion: """
            Runs the shared samtools markdup workflow on every unmarked alignment track in a
            .lungfishref bundle and attaches each result as a new "[dup-marked]" track under
            alignments/marked/. The source tracks are kept on disk and renamed "[unmarked]";
            nothing is deleted. Running the command again on the same bundle is a no-op error
            once every track has a marked copy. This is the CLI equivalent of the Inspector's
            "Mark Duplicates in Bundle Tracks" action.

            Examples:
              lungfish-cli bundle mark-duplicates MyGenome.lungfishref
              lungfish-cli bundle mark-duplicates MyGenome.lungfishref --format json
            """
    )

    @Argument(help: "Path to the .lungfishref bundle to update in place")
    var bundlePath: String

    @OptionGroup var globalOptions: TextAndJSONGlobalOptions

    func run() async throws {
        let resolvedOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
        if resolvedOptions.outputFormat == .json {
            try await execute(eventsOn: true, quiet: resolvedOptions.quiet, emit: printEventLine)
        } else {
            try await execute(eventsOn: false, quiet: resolvedOptions.quiet, emit: { print($0) })
        }
    }

    /// The run, with each line handed to `emit`, so a test can keep them. With `eventsOn` standard
    /// output holds only `CLIEvent` lines (Phase 2.10 lane A54): a `start` with the row's first
    /// detail, a `progress` for each stage of the service, and a `complete` that names the bundle
    /// and says how many tracks were marked. SIGTERM, the app's Cancel, cancels the service and the
    /// run is recorded as cancelled with exit 125. Tracks marked before the cancel stay attached.
    func execute(
        eventsOn: Bool,
        quiet: Bool,
        emit: @escaping (String) -> Void,
        service: DuplicateWorkflowRunner? = nil
    ) async throws {
        let startedAt = Date()
        let output = AlignmentWorkflowLeafOutput(eventsOn: eventsOn, quiet: quiet, emit: emit)
        output.events.emitStart("Marking duplicates...")
        let command = [CLICommandIdentity.executableName, "bundle", "mark-duplicates", bundlePath]
        let path = bundlePath
        let progress = output.progressHandler
        let work: DuplicateWorkflowRunner = service ?? { progress in
            try await CLIMarkDuplicatesBundleSupport.run(
                bundlePath: path, outputFormat: .text, quiet: true, command: command, progress: progress
            ) { _ in }
        }
        let ran = await runCancellingOnSIGTERM { try await work(progress) }
        switch ran {
        case .success(let result):
            let tracks = "\(result.processedTracks) alignment track\(result.processedTracks == 1 ? "" : "s")"
            output.events.emitComplete(outputs: [result.bundleURL.path], message: "Marked duplicates in \(tracks).")
            output.say("Bundle: \(result.bundleURL.path)")
            output.say("Processed tracks: \(result.processedTracks)")
            output.say("Marked tracks added: \(result.newTrackIds.joined(separator: ", "))")
            output.say("Original tracks kept as [unmarked]: \(result.retainedTrackIds.joined(separator: ", "))")
        case .failure(let error):
            if error is CancellationError || SIGTERMCancellation.signalCaught {
                let record = CancelledAlignmentWorkflowRecord(
                    workflow: "lungfish bundle mark-duplicates",
                    argv: command,
                    explicit: ["bundle": .string(bundlePath)],
                    note: "Cancelled while marking duplicates. Tracks marked before the cancel stay attached to the bundle.",
                    startedAt: startedAt,
                    url: CancelledAlignmentWorkflowRecord.newURL(
                        in: CancelledAlignmentWorkflowRecord.folder(in: URL(fileURLWithPath: bundlePath, isDirectory: true)),
                        workflow: "lungfish bundle mark-duplicates"
                    )
                )
                throw output.cancelled("Marking cancelled. Tracks marked before the cancel stay attached.", record: record)
            }
            if error is CLIError || (error as? AlignmentDuplicateError)?.isRefusal == true {
                throw output.refused(error.localizedDescription)
            }
            throw output.failed(error.localizedDescription)
        }
    }
}

extension AlignmentDuplicateError {
    /// Whether the service stopped before it changed anything, which a leaf ends with exit 3. The service
    /// throws `.sourcePathNotFound` and `.samtoolsFailed` in its per-track loop, after an earlier track may
    /// already be attached, so those two are failures (exit 64). Both duplicate leaves read this.
    var isRefusal: Bool {
        switch self {
        case .noAlignmentTracks, .allTracksAlreadyMarked:
            return true
        case .sourcePathNotFound, .samtoolsFailed:
            return false
        }
    }
}
