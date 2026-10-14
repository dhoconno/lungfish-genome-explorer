// BundleDeduplicateAlignmentsSubcommand.swift - Create a bundle with duplicate reads removed from alignment tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Deduplicate Alignments Subcommand

struct BundleDeduplicateAlignmentsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deduplicate-alignments",
        abstract: "Create a bundle with duplicate reads removed from alignment tracks",
        discussion: """
            Copies a .lungfishref bundle, runs the shared duplicate-removal workflow on
            every alignment track, and records reproducibility provenance in the output bundle.

            Examples:
              lungfish-cli bundle deduplicate-alignments MyGenome.lungfishref
              lungfish-cli bundle deduplicate-alignments MyGenome.lungfishref --output MyGenome-dedup.lungfishref
            """
    )

    @Argument(help: "Path to the source .lungfishref bundle")
    var bundlePath: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output .lungfishref bundle path")
    var output: String?

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
    /// detail, a `progress` for each stage of the service, and a `complete` that names the new bundle
    /// and says how many tracks were processed. SIGTERM, the app's Cancel, cancels the service and
    /// the run is recorded as cancelled with exit 125. The source bundle is never changed. The service
    /// removes the copy it made when it stops, so a copy remains only where the output path was taken
    /// before the run, and the cancel says which of the two holds.
    func execute(
        eventsOn: Bool,
        quiet: Bool,
        emit: @escaping (String) -> Void,
        service: DuplicateWorkflowRunner? = nil
    ) async throws {
        let startedAt = Date()
        let events = AlignmentWorkflowLeafOutput(eventsOn: eventsOn, quiet: quiet, emit: emit)
        events.events.emitStart("Creating deduplicated bundle...")
        var command = [CLICommandIdentity.executableName, "bundle", "deduplicate-alignments", bundlePath]
        if let output {
            command += ["--output", output]
        }
        let (source, destination, argv) = (bundlePath, output, command)
        let progress = events.progressHandler
        let work: DuplicateWorkflowRunner = service ?? { progress in
            try await CLIDeduplicatedBundleSupport.run(
                sourceBundlePath: source, outputBundlePath: destination, outputFormat: .text, quiet: true,
                command: argv, progress: progress
            ) { _ in }
        }
        let ran = await runCancellingOnSIGTERM { try await work(progress) }
        switch ran {
        case .success(let result):
            let tracks = "\(result.processedTracks) alignment track\(result.processedTracks == 1 ? "" : "s")"
            events.events.emitComplete(
                outputs: [result.bundleURL.path],
                message: "Created \(result.bundleURL.lastPathComponent) from \(tracks)."
            )
            events.say("Deduplicated bundle: \(result.bundleURL.path)")
            events.say("Processed tracks: \(result.processedTracks)")
        case .failure(let error):
            if error is CancellationError || SIGTERMCancellation.signalCaught {
                let sourceURL = URL(fileURLWithPath: bundlePath)
                let expected = output.map { URL(fileURLWithPath: $0) }
                    ?? sourceURL.deletingLastPathComponent().appendingPathComponent(
                        "\(sourceURL.deletingPathExtension().lastPathComponent)-deduplicated.lungfishref"
                    )
                // The service writes to `expected` whenever that path was free, and removes what it wrote
                // when it stops. A folder there after the cancel was not made by this run's copy, or the
                // copy itself failed part way, so the leaf cannot say none remains.
                let left = FileManager.default.fileExists(atPath: expected.path)
                    ? "a partly written copy may remain beside it" : "no partial copy remains"
                let record = CancelledAlignmentWorkflowRecord(
                    workflow: "lungfish bundle deduplicate-alignments",
                    argv: command,
                    explicit: ["sourceBundle": .string(bundlePath)],
                    note: "Cancelled while creating the deduplicated bundle. The source bundle was not changed, and \(left).",
                    startedAt: startedAt,
                    url: URL(fileURLWithPath: expected.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
                )
                throw events.cancelled(
                    "Deduplication cancelled. The source bundle was not changed, and \(left).",
                    record: record
                )
            }
            if error is CLIError || error is AlignmentDuplicateError {
                throw events.refused(error.localizedDescription)
            }
            throw events.failed(error.localizedDescription)
        }
    }
}
