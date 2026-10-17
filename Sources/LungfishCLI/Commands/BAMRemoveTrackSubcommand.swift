// BAMRemoveTrackSubcommand.swift - lungfish-cli bam remove-track
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension BAMCommand {
    /// Removes a derived alignment track from a bundle, the Inspector's Remove Derived Alignment
    /// (Phase 2.10 lane A51, census row 13).
    ///
    /// `BundleAlignmentTrackRemovalService` saves the manifest without the track, writes the record
    /// that names each removed file with its digest, and only then deletes the files. SIGTERM, the
    /// app's Cancel, stops the run while it hashes the files, before the manifest changes. The run is
    /// then recorded as cancelled and the command exits 125. Once the manifest has changed the
    /// removal finishes. With `--format json` standard output holds only `CLIEvent` lines.
    struct RemoveTrackSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove-track",
            abstract: "Remove a derived alignment track and its files from a bundle",
            discussion: """
                Removes a track that bam filter derived, with its BAM, index, statistics database and \
                their records. A source alignment cannot be removed. The record of the removal names \
                each removed file with its digest and is written to \
                provenance/removals/<track>.lungfish-provenance.json in the bundle before any file goes.
                """
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle (.lungfishref)")
        var bundlePath: String

        @Option(name: .customLong("track"), help: "ID of the derived alignment track to remove")
        var trackID: String

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        func validate() throws {
            if bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--bundle must not be empty.")
            }
            if trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--track must not be empty.")
            }
        }

        func run() async throws {
            let options = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            try await execute(eventsOn: options.outputFormat == .json, quiet: options.quiet, emit: printEventLine)
        }

        /// The run, with each event line handed to `emit`, so a test can keep them.
        func execute(eventsOn: Bool, quiet: Bool, emit: @escaping (String) -> Void) async throws {
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            let say: (String) -> Void = { text in
                if eventsOn || !quiet { printHumanLine(text, eventsOn: eventsOn) }
            }
            let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true).standardizedFileURL
            guard let manifest = try? BundleManifest.load(from: bundleURL) else {
                throw refuse("No bundle manifest at \(bundleURL.path). Pass the .lungfishref folder as --bundle.", events)
            }
            let trackName = manifest.alignments.first { $0.id == trackID }?.name ?? trackID
            events.emitStart("Removing \(trackName)...")
            say("Removing \(trackName)...")

            switch await removeCancellingOnSIGTERM(bundleURL: bundleURL) {
            case .success(let result):
                for url in result.leftoverArtifactURLs {
                    let warning = "Could not delete \(url.lastPathComponent), which the bundle no longer names."
                    events.emitLog(.warning, warning)
                    say("Warning: \(warning)")
                }
                let message = "Removed derived alignment track \"\(result.removedTrack.name)\"."
                let record = result.recordURL ?? BundleAlignmentTrackRemovalRecord.recordURL(bundleURL: bundleURL, trackID: trackID)
                events.emitComplete(outputs: [record.path], message: message)
                say(message)
            case .failure(let error) where error is CancellationError:
                events.emitFailed("Removal cancelled. The bundle was not changed.")
                say("Removal cancelled. The bundle was not changed.")
                throw CLIExitCode.cancelled.exitCode
            case .failure(let error as BundleAlignmentTrackRemovalError):
                throw refuse(error.localizedDescription, events)
            case .failure(let error):
                events.emitFailed("Remove Derived Alignment failed: \(CLIFailureWords.describe(error))")
                say("Error: \(CLIFailureWords.describe(error))")
                throw CLIExitCode.workflowError.exitCode
            }
        }

        /// Runs the removal so that SIGTERM cancels it instead of ending the command. The command
        /// listens before the task starts, so a SIGTERM caught before then cancels the task as soon
        /// as it exists, and a second SIGTERM ends the command at once.
        private func removeCancellingOnSIGTERM(bundleURL: URL) async -> Result<BundleAlignmentTrackRemovalResult, any Error> {
            let pendingCancel = PendingTaskCancel<Result<BundleAlignmentTrackRemovalResult, any Error>>()
            let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
            defer { termination.end() }
            let trackID = trackID
            let task = Task { () -> Result<BundleAlignmentTrackRemovalResult, any Error> in
                do {
                    return .success(try await BundleAlignmentTrackRemovalService()
                        .removeDerivedAlignmentTrack(bundleURL: bundleURL, trackID: trackID))
                } catch {
                    return .failure(error)
                }
            }
            pendingCancel.attach(task)
            return await task.value
        }

        /// A refusal before anything changed, which exits 3 and names the fix.
        private func refuse(_ message: String, _ events: CLIEventEmitter) -> ExitCode {
            events.emitFailed(message)
            printHumanLine("Error: \(message)", eventsOn: true)
            return CLIExitCode.inputError.exitCode
        }
    }
}
