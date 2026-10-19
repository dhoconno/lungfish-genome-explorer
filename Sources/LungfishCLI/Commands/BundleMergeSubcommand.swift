// BundleMergeSubcommand.swift - Merge reference bundles into one new reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// A refusal of `bundle merge` before it writes anything, which exits 3 and names the fix.
struct BundleMergeRefusal: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BundleMergeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge reference bundles into one new reference bundle",
        discussion: """
            Concatenates the sequences of two or more .lungfishref bundles into one new bundle and
            carries their annotation tracks across as separate tracks named for their source. Bundles
            with variant, signal or alignment tracks are refused, because their coordinates would have
            to be rebased onto the merged reference, and so are sequence names that two bundles share.
            The new bundle is built in the project's .tmp folder and published under its name with one
            rename, so no reader sees a part of it. SIGTERM stops the run before it publishes, records
            it as cancelled and exits 125. This is the CLI equivalent of the sidebar's Merge into New
            Bundle for reference bundles.

            Examples:
              lungfish-cli bundle merge A.lungfishref B.lungfishref --name "Merged Genomes"
              lungfish-cli bundle merge A.lungfishref B.lungfishref --name Merged --output-dir ./out --format json
            """
    )

    static let cancelledMessage = "Merge cancelled. Nothing was published."

    @Argument(help: "Paths of the .lungfishref bundles to merge, at least two")
    var bundles: [String]

    @Option(name: .long, help: "Name of the merged bundle")
    var name: String

    @Option(
        name: [.customShort("o"), .customLong("output-dir")],
        help: "Folder to create the merged bundle in. Defaults to the folder of the first bundle"
    )
    var outputDirectory: String?

    @OptionGroup var globalOptions: GlobalOptions

    /// With `--format json` standard output holds only `CLIEvent` lines, with the words the app's row
    /// shows. SIGTERM, the app's Cancel, stops the run before it publishes, records it as cancelled
    /// beside the bundle it would have published and exits 125. A refusal exits 3.
    func run() async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        let startedAt = Date()
        let pendingCancel = PendingTaskCancel<Result<URL, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let command = self
        let task = Task { () -> Result<URL, any Error> in
            do {
                return .success(try await command.merge(events: events))
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel.
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        switch outcome {
        case .success(let bundleURL):
            events.emitComplete(output: bundleURL.path, message: "Merged \(bundles.count) reference bundles")
            if !globalOptions.quiet {
                printHumanLine("Merged \(bundles.count) reference bundles into \(bundleURL.path)", eventsOn: eventsOn)
            }
        case .failure(let error) where error is CancellationError:
            await recordCancelledRun(startedAt: startedAt)
            events.emitFailed(Self.cancelledMessage)
            printHumanLine(Self.cancelledMessage, eventsOn: eventsOn)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let error) where error is BundleMergeRefusal || error is ReferenceBundleMergeServiceError:
            events.emitFailed(CLIFailureWords.describe(error))
            printHumanLine(CLIFailureWords.describe(error), eventsOn: eventsOn)
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            events.emitFailed(CLIFailureWords.describe(error))
            printHumanLine(CLIFailureWords.describe(error), eventsOn: eventsOn)
            throw CLIExitCode.workflowError.exitCode
        }
    }

    /// The run, which returns the published bundle.
    private func merge(events: CLIEventEmitter) async throws -> URL {
        guard bundles.count >= 2 else { throw ReferenceBundleMergeServiceError.requiresAtLeastTwoBundles }
        let sources = bundles.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BundleMergeRefusal("No reference bundle at \(source.path). bundle merge reads .lungfishref folders.")
            }
        }
        let bundleName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleName.isEmpty else { throw BundleMergeRefusal("--name is empty. Give the merged bundle a name.") }
        // The service creates the folder once it has accepted the sources, so a refusal leaves none.
        let directory = destination(sources: sources)

        events.emitStart("Merging \(sources.count) reference bundles")
        events.emitProgress(0, message: "Preparing to merge \(sources.count) reference bundles\u{2026}")
        let reporter = ReferenceBundleMergeService.ProgressReporter { fraction, detail, log in
            events.emitProgress(fraction, message: detail)
            if let log { events.emitLog(log.level == .warning ? .warning : .info, log.message) }
        }
        return try await ReferenceBundleMergeService.runDetached(
            sourceBundleURLs: sources,
            outputDirectory: directory,
            bundleName: bundleName,
            provenanceWriter: .live,
            reporter: reporter,
            observedArguments: Self.observedArguments()
        )
    }

    /// The folder the merged bundle is created in.
    private func destination(sources: [URL]) -> URL {
        outputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? sources[0].deletingLastPathComponent()
    }

    /// The words the process was started with when it runs `bundle merge`, which the record names.
    private static func observedArguments() -> [String]? {
        let raw = CommandLine.arguments
        guard let executable = raw.first else { return nil }
        let arguments = Array(raw.dropFirst())
        let normalized = LungfishCLI.normalizedArgumentsForParsing(arguments)
        guard normalized.starts(with: ["bundle", "merge"]) else { return nil }
        return [executable] + arguments
    }

    /// Records the run a cancel stopped as cancelled, beside the bundle it would have published. A
    /// failure to write it does not hide the cancel.
    private func recordCancelledRun(startedAt: Date) async {
        let sources = bundles.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        guard let first = sources.first else { return }
        let directory = destination(sources: [first])
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: ReferenceBundleMergeService.commandName,
            parameters: [
                "bundles": .array(sources.map { .file($0) }),
                "name": .string(name),
                "outputDirectory": .file(directory),
            ],
            toolName: ReferenceBundleMergeService.commandName,
            toolVersion: LungfishCLI.configuration.version,
            command: Self.observedArguments() ?? [CLICommandIdentity.executableName, "bundle", "merge"] + bundles,
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: Self.cancelledMessage,
            status: .cancelled,
            outputDirectory: directory,
            writeFileSidecars: false
        )
    }
}
