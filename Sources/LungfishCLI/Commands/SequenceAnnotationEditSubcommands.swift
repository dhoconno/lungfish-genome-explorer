// SequenceAnnotationEditSubcommands.swift - Add an annotation or attach an annotation track to a reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The two bundle edits of family L1 that had no command (2.10 A42, plan decision C3). Each leaf calls
/// the Workflow function the app calls, so the bundle and its records equal what the app writes, and
/// each record names the command that reproduces the edit. With `--format json` a leaf writes only
/// `CLIEvent` lines on standard output, and its start and complete messages are the words the app's
/// row shows.
extension SequenceCommand {
    /// Adds one feature to the bundle's manual annotation track through
    /// `ReferenceBundleManualAnnotationService.addAnnotation`, the function the Add Annotation menu
    /// item calls.
    struct AddAnnotation: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-annotation",
            abstract: "Add one annotation to the manual annotation track of a reference bundle."
        )

        @Argument(help: "Reference bundle to update")
        var bundle: String

        @Option(help: "Sequence or chromosome the annotation lies on.")
        var chromosome: String

        @Option(help: "0-based inclusive start coordinate.")
        var start: Int

        @Option(help: "0-based exclusive end coordinate.")
        var end: Int

        @Option(help: "Feature name.")
        var name: String

        @Option(help: "Feature type (GenBank/GFF3-style, e.g. gene, CDS).")
        var type: String

        @Option(help: "Strand: +, -, or . for unknown.")
        var strand: String = "."

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            guard start >= 0, end > start else {
                throw ValidationError("--start must be 0 or more and less than --end.")
            }
            guard Strand(rawValue: strand) != nil else {
                throw ValidationError("--strand must be +, - or . for unknown.")
            }
            guard AnnotationType(rawValue: type) != nil else {
                throw ValidationError("Unknown --type '\(type)'. Use a feature type such as gene, CDS, exon or region.")
            }
        }

        func run() async throws {
            try await execute(emit: { printEventLine($0) })
        }

        /// The run, with each event line handed to `emit`.
        func execute(emit: @escaping (String) -> Void) async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            events.emitStart("Adding \(name)...")
            do {
                let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
                let manifest = try BundleManifest.load(from: bundleURL)
                guard let sequence = manifest.genome?.chromosomes.first(where: { $0.name == chromosome }) else {
                    throw ValidationError("The bundle holds no sequence named '\(chromosome)'. Pass a sequence of its genome.")
                }
                guard end <= Int(sequence.length) else {
                    throw ValidationError("--end \(end) is past the end of \(chromosome), which is \(sequence.length) bases long.")
                }
                let annotation = SequenceAnnotation(
                    type: AnnotationType(rawValue: type) ?? .region,
                    name: name,
                    chromosome: chromosome,
                    intervals: [AnnotationInterval(start: start, end: end)],
                    strand: Strand(rawValue: strand) ?? .unknown
                )
                let result = try await ReferenceBundleManualAnnotationService(toolName: CLICommandIdentity.executableName).addAnnotation(
                    annotation,
                    toBundleAt: bundleURL,
                    invocationArgv: recordedArguments(bundleURL: bundleURL)
                )
                events.emitComplete(output: result.bundleURL.path, message: "Added annotation to \(result.track.name)")
                if !globalOptions.quiet {
                    printHumanLine("Added annotation \(name) to \(result.track.name).", eventsOn: eventsOn)
                }
            } catch {
                events.emitFailed(CLIFailureWords.describe(error))
                throw error
            }
        }

        /// The argv the record names, the words the process was started with, or, for a run inside
        /// another process, the command the app's row records for the same edit.
        func recordedArguments(bundleURL: URL) -> [String] {
            observedProcessSequenceCommandArguments(subcommand: "add-annotation")
                ?? [CLICommandIdentity.executableName] + ReferenceBundleManualAnnotationService.annotationAddArguments(
                    chromosome: chromosome,
                    start: start,
                    end: end,
                    name: name,
                    type: type,
                    strand: strand,
                    bundleURL: bundleURL
                )
        }
    }

    /// Attaches a GFF3, GTF or BED file to the bundle as a new annotation track through
    /// `ReferenceBundleAnnotationImportService.attachAnnotationTrack`, the function the Import Center
    /// and a file dropped on the sidebar call.
    struct AttachTrack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "attach-track",
            abstract: "Attach a GFF3, GTF or BED file to a reference bundle as an annotation track."
        )

        @Argument(help: "Reference bundle to update")
        var bundle: String

        @Argument(help: "GFF3, GTF or BED file to attach")
        var annotationFile: String

        @Option(name: .customLong("track-id"), help: "Annotation track ID. Made from the file name when omitted.")
        var trackID: String?

        @Option(name: .customLong("track-name"), help: "Annotation track display name. Made from the file name when omitted.")
        var trackName: String?

        @OptionGroup var globalOptions: GlobalOptions

        /// Runs the attach so that SIGTERM cancels it instead of ending the command, as the
        /// app's Cancel does (plan decision C5). The attach then leaves the bundle as it was, and
        /// the command exits 125. The command listens before the task starts, so an early
        /// SIGTERM cancels the task once it exists, and a second SIGTERM ends the command at once.
        func run() async throws {
            let pendingCancel = PendingTaskCancel<(any Error)?>()
            // The task's cancel runs the attach's cancellation handler before it returns, so once this
            // line is out, the attach stops at its next check, before its read or after the parse.
            let termination = SIGTERMCancellation(secondSignalEndsProcess: true) {
                pendingCancel.cancel()
                FileHandle.standardError.write(Data("Cancelling the attach.\n".utf8))
            }
            defer { termination.end() }
            let task = Task { () -> (any Error)? in
                do {
                    try await self.execute(emit: { printEventLine($0) })
                    return nil
                } catch {
                    return error
                }
            }
            pendingCancel.attach(task)
            guard let error = await task.value else { return }
            if error is CancellationError {
                FileHandle.standardError.write(Data("Attach cancelled. The bundle is as it was.\n".utf8))
                throw CLIExitCode.cancelled.exitCode
            }
            throw error
        }

        /// The run, with each event line handed to `emit`.
        func execute(emit: @escaping (String) -> Void) async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
            let sourceURL = URL(fileURLWithPath: annotationFile).standardizedFileURL
            events.emitStart("Importing \(sourceURL.lastPathComponent)...")
            do {
                try Self.checkPaths(source: sourceURL, bundle: bundleURL)
                let result = try await ReferenceBundleAnnotationImportService(toolName: CLICommandIdentity.executableName, toolKind: CLICommandIdentity.recordedToolKind).attachAnnotationTrack(
                    sourceURL: sourceURL,
                    bundleURL: bundleURL,
                    trackID: trackID,
                    trackName: trackName,
                    invocationArgv: recordedArguments(sourceURL: sourceURL, bundleURL: bundleURL)
                )
                let message = "Imported \(result.featureCount) annotations"
                events.emitComplete(output: result.bundleURL.path, message: message)
                if !globalOptions.quiet {
                    printHumanLine("\(message) into track \(result.track.id).", eventsOn: eventsOn)
                }
            } catch is CancellationError {
                // A cancel is not a failure. The app's transport reports it from the exit.
                throw CancellationError()
            } catch {
                events.emitFailed(CLIFailureWords.describe(error))
                throw error
            }
        }

        /// The attach reads `source` and writes inside `bundle`, so both are checked before the
        /// service writes anything. The service then checks the format, the manifest and the track ID.
        static func checkPaths(source: URL, bundle: URL) throws {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ValidationError("No annotation file at \(source.path). Pass a GFF3, GTF or BED file.")
            }
            guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("No reference bundle at \(bundle.path). Pass a .lungfishref folder.")
            }
        }

        /// The argv the records name, the words the process was started with, or, for a run inside
        /// another process, the command the app's row records for the same attach.
        func recordedArguments(sourceURL: URL, bundleURL: URL) -> [String] {
            observedProcessSequenceCommandArguments(subcommand: "attach-track")
                ?? [CLICommandIdentity.executableName] + ReferenceBundleAnnotationImportService.attachTrackArguments(
                    sourceURL: sourceURL, bundleURL: bundleURL, trackID: trackID, trackName: trackName
                )
        }
    }
}
