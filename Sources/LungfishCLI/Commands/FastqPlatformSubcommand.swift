// FastqPlatformSubcommand.swift - Shows, checks and corrects the sequencing platform of FASTQ bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import Synchronization

/// `lungfish-cli fastq platform`. The Inspector's platform notice and its read
/// type popup run this command, so a label change always has a provenance record.
struct FastqPlatformSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "platform",
        abstract: "Show, check or correct the sequencing platform recorded for FASTQ bundles",
        discussion: """
            With no option, prints the platform and read type each bundle records,
            how they were decided, and what the read headers show.

            --check lists bundles whose recorded label contradicts the reads. It
            exits 0 when every label is consistent and 11 when one is suspect. Pass
            a project folder to check every FASTQ bundle in it.

            --set, --read-type and --confirm change the label of the listed bundles. Only
            the bundle's metadata file is rewritten, never the reads, and a
            provenance record beside that file names the change.

            Examples:
              lungfish-cli fastq platform Sample.lungfishfastq
              lungfish-cli fastq platform MyProject.lungfish --check
              lungfish-cli fastq platform Sample.lungfishfastq --set ont
              lungfish-cli fastq platform Sample.lungfishfastq --read-type pacbio-hifi
              lungfish-cli fastq platform Sample.lungfishfastq --confirm
            """
    )

    /// Exit status of `--check` when a suspect label was found.
    static let suspectExitCode: Int32 = 11

    @Argument(help: "FASTQ bundles, or a project folder with --check")
    var inputs: [String]

    @Flag(name: .customLong("check"), help: "List bundles whose recorded platform contradicts the reads")
    var check: Bool = false

    @Option(
        name: .customLong("set"),
        help: "Record this platform: illumina, ont, pacbio, element, mgi, ultima or unknown"
    )
    var setPlatform: String?

    @Option(
        name: .customLong("read-type"),
        help: "Record this read type: illumina-short-reads, ont-reads, pacbio-hifi, or auto to clear it (default: the one the platform implies)"
    )
    var readType: String?

    @Flag(name: .customLong("confirm"), help: "Keep the recorded label and stop the suspect-label notice")
    var confirm: Bool = false

    @Flag(
        name: .customLong("include-derivatives"),
        help: "Apply the change to derived bundles of the same root in the project too"
    )
    var includeDerivatives: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        guard !inputs.isEmpty else { throw ValidationError("Give at least one FASTQ bundle.") }
        let changes = [setPlatform != nil || readType != nil, confirm].filter { $0 }.count
        if changes > 1 { throw ValidationError("--confirm cannot be combined with --set or --read-type.") }
        if changes == 1, check { throw ValidationError("--check cannot be combined with a change.") }
        if includeDerivatives, changes == 0 { throw ValidationError("--include-derivatives needs --set, --read-type or --confirm.") }
        if let setPlatform, Self.parsePlatform(setPlatform) == nil {
            throw ValidationError("Unknown platform '\(setPlatform)'. Valid: \(Self.platformValues.joined(separator: ", ")).")
        }
        if let readType, Self.parseReadType(readType) == nil, readType.lowercased() != Self.clearReadTypeValue {
            throw ValidationError("Unknown read type '\(readType)'. Valid: illumina-short-reads, ont-reads, pacbio-hifi, auto.")
        }
    }

    static let platformValues = ["illumina", "ont", "pacbio", "element", "mgi", "ultima", "unknown"]
    /// `--read-type auto` clears the recorded read type, so detection decides.
    static let clearReadTypeValue = "auto"

    static func parsePlatform(_ value: String) -> SequencingPlatform? {
        guard case .given(let platform)? = ImportPlatformRequest(cliValue: value) else { return nil }
        return platform
    }

    static func parseReadType(_ value: String) -> FASTQAssemblyReadType? {
        switch value.lowercased() {
        case "illumina-short-reads": return .illuminaShortReads
        case "ont-reads": return .ontReads
        case "pacbio-hifi": return .pacBioHiFi
        default: return nil
        }
    }

    static func cliValue(of readType: FASTQAssemblyReadType) -> String {
        switch readType {
        case .illuminaShortReads: return "illumina-short-reads"
        case .ontReads: return "ont-reads"
        case .pacBioHiFi: return "pacbio-hifi"
        }
    }

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let urls = inputs.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            print(formatter.error("Input not found: \(url.path)"))
            throw CLIExitCode.inputError.exitCode
        }

        if setPlatform != nil || readType != nil || confirm {
            try await runChangeCancellingOnSIGTERM(bundleURLs: urls)
            return
        }

        let bundles = check ? urls.flatMap(FASTQPlatformLabelService.bundles(under:)) : urls
        var reports: [FASTQPlatformLabelService.Report] = []
        for bundle in bundles {
            do {
                reports.append(try FASTQPlatformLabelService.report(forBundle: bundle))
            } catch {
                if !check {
                    print(formatter.error(error.localizedDescription))
                    throw CLIExitCode.inputError.exitCode
                }
            }
        }
        let shown = check ? reports.filter(\.check.isSuspect) : reports
        if globalOptions.outputFormat == .json {
            Self.printJSON(shown)
        } else if !globalOptions.quiet {
            if check {
                print(shown.isEmpty
                    ? formatter.success("Checked \(reports.count) FASTQ bundle(s). Every recorded platform agrees with the reads.")
                    : formatter.warning("\(shown.count) of \(reports.count) FASTQ bundle(s) record a platform the reads contradict."))
            }
            for report in shown { print(Self.describe(report)) }
        }
        if check, !shown.isEmpty {
            throw ExitCode(Self.suspectExitCode)
        }
    }

    /// Records the change so that SIGTERM cancels it instead of ending the command (Phase 2.11 lane S61,
    /// decisions P2 and C5). The Inspector's platform notice stops this command with SIGTERM and gives it
    /// `operationGrace`. The run ends at its next step and restores the metadata files it had changed.
    /// It records itself as cancelled under the first bundle's `provenance/cancelled` folder, ends the
    /// stream with one `failed` line, and exits 125.
    private func runChangeCancellingOnSIGTERM(bundleURLs: [URL]) async throws {
        let startedAt = Date()
        let restoreNote = RestoreFailureNote()
        let ran = await runCancellingOnSIGTERM { [self] in
            try await runChange(
                bundleURLs: bundleURLs, formatter: TerminalFormatter(useColors: globalOptions.useColors),
                restoreNote: restoreNote
            )
        }
        guard case .failure(let error) = ran else { return }
        let restoreFailure = restoreNote.reason.map { PlatformRestoreFailure(reason: $0) }
        guard restoreFailure != nil || error is CancellationError || SIGTERMCancellation.signalCaught else { throw error }
        let output = AlignmentWorkflowLeafOutput(
            eventsOn: globalOptions.outputFormat == .json,
            quiet: globalOptions.quiet,
            emit: { printEventLine($0) }
        )
        let workflow = "lungfish fastq platform"
        // A restore that failed leaves the labels changed. Neither the stream nor the record may say they
        // were restored, and the command exits with the output error status and not 125 (review S61, Fix 10).
        let message = restoreFailure.map {
            "The platform label change was cancelled, but restoring the recorded labels failed. \($0.reason)"
        } ?? "Platform label change cancelled. The recorded labels were restored."
        let note = restoreFailure.map {
            "Cancelled before the label change finished. Restoring the recorded labels failed, so they may still show the change. \($0.reason)"
        } ?? "Cancelled before the label change finished. The recorded labels were restored."
        let cancelledStatus = output.cancelled(
            message,
            record: CancelledAlignmentWorkflowRecord(
                workflow: workflow,
                argv: [CLICommandIdentity.executableName] + CommandLine.arguments.dropFirst(),
                explicit: [:],
                note: note,
                startedAt: startedAt,
                url: CancelledAlignmentWorkflowRecord.newURL(
                    in: CancelledAlignmentWorkflowRecord.folder(in: bundleURLs[0]), workflow: workflow
                )
            )
        )
        throw restoreFailure == nil ? cancelledStatus : CLIExitCode.outputError.exitCode
    }

    /// The restore after a cancel threw, so the labels may still show the change.
    private struct PlatformRestoreFailure: Error {
        let reason: String
    }

    /// Where `runChange` leaves the reason a restore after a cancel failed. `runCancellingOnSIGTERM` turns
    /// every error of a signalled run into a plain cancel, so the reason travels beside the error.
    final class RestoreFailureNote: Sendable {
        private let storage = Mutex<String?>(nil)
        func record(_ reason: String) { storage.withLock { $0 = reason } }
        var reason: String? { storage.withLock { $0 } }
    }

    private func runChange(
        bundleURLs: [URL], formatter: TerminalFormatter, restoreNote: RestoreFailureNote = RestoreFailureNote()
    ) async throws {
        let runClock = ProvenanceRunClock()
        let platform = setPlatform.flatMap(Self.parsePlatform)
        let explicitReadType = readType.flatMap(Self.parseReadType)
        let clearReadType = readType?.lowercased() == Self.clearReadTypeValue
        let source: PlatformAssignment.Source = confirm ? .userConfirmed : .userCorrected
        let events = CLIEventEmitter(enabled: globalOptions.outputFormat == .json) { printEventLine($0) }
        events.emitStart(message: "Recording the sequencing platform of \(bundleURLs.count) FASTQ bundle(s)")

        var targets: [URL] = []
        for bundleURL in bundleURLs {
            targets.append(bundleURL)
            if includeDerivatives {
                let searchRoot = Self.projectFolder(containing: bundleURL) ?? bundleURL.deletingLastPathComponent()
                targets += FASTQPlatformLabelService.derivedBundles(ofRoot: bundleURL, searchingFrom: searchRoot)
            }
        }

        let sidecars: [URL]
        let snapshot: ProvenancePublicationSnapshot
        do {
            sidecars = try targets.map { try FASTQMetadataStore.metadataURL(for: FASTQPlatformLabelService.labelledFASTQURL(forBundle: $0)) }
            snapshot = try ProvenancePublicationSnapshot(
                urls: sidecars.flatMap { sidecar in
                    [sidecar] + ProvenancePublicationArtifacts.fileSidecarArtifacts(for: sidecar)
                },
                backupNamePrefix: "lungfish-fastq-platform"
            )
        } catch {
            // The run began, so a throw before the first change ends the stream with one failed
            // line too, such as a folder that is not a bundle. The command fails with the same
            // error, which the app reads from the exit status (review of lane C4, ruling 3).
            events.emitFailed(CLIFailureWords.describe(error))
            throw error
        }
        defer { snapshot.discard() }
        let inputRecords = sidecars.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ProvenanceRecorder.fileRecord(url: $0, format: .json, role: .input) }

        var changes: [FASTQPlatformLabelService.Change] = []
        do {
            for target in targets {
                try Task.checkCancellation()
                changes.append(try FASTQPlatformLabelService.apply(
                    toBundle: target,
                    platform: confirm ? nil : platform,
                    readType: confirm ? nil : explicitReadType,
                    clearReadType: !confirm && clearReadType,
                    source: source
                ))
            }
            try Task.checkCancellation()
            for change in changes {
                try await recordProvenance(change: change, inputs: inputRecords, runClock: runClock)
            }
        } catch {
            // A cancel writes no failure here, since `runChangeCancellingOnSIGTERM` ends the stream with the
            // cancelled one once the labels are restored. Any other failure is reported before the
            // restore, so a restore that throws still leaves the stream with its one terminal event.
            let cancelled = error is CancellationError || Task.isCancelled
            if !cancelled {
                if globalOptions.outputFormat == .json {
                    events.emitFailed(CLIFailureWords.describe(error))
                } else {
                    print(formatter.error(CLIFailureWords.describe(error)))
                }
            }
            // When the first change fails nothing was written, since each
            // metadata file is replaced atomically. Restoring would only
            // rewrite the same files, and a locked one would hide the reason.
            if !changes.isEmpty {
                do {
                    try snapshot.restore()
                } catch where cancelled {
                    // The cancel came first, but the labels stay changed. Say so, so that the cancel path
                    // does not record them as restored (review S61, Fix 10).
                    restoreNote.record(error.localizedDescription)
                    throw error
                }
            }
            if cancelled { throw CancellationError() }
            throw CLIExitCode.outputError.exitCode
        }

        if globalOptions.outputFormat == .json {
            events.emitComplete(
                outputs: changes.map(\.sidecarURL.path),
                message: "Recorded the platform of \(changes.count) FASTQ bundle(s)"
            )
        } else if !globalOptions.quiet {
            for change in changes {
                let platformText = change.platform?.displayName ?? "no platform"
                let readText = change.readType?.displayName ?? "no read type"
                let verb = change.source == .userConfirmed ? "Kept" : "Recorded"
                print(formatter.success("\(verb) \(platformText), \(readText) for \(change.bundleURL.lastPathComponent)."))
            }
        }
    }

    /// The command line this change replays as.
    func replayCommand(bundleURL: URL) -> [String] {
        var command = [CLICommandIdentity.executableName, "fastq", "platform", bundleURL.path]
        if let setPlatform, let platform = Self.parsePlatform(setPlatform) {
            command += ["--set", platform.importCLIValue]
        }
        if let readType, let parsed = Self.parseReadType(readType) {
            command += ["--read-type", Self.cliValue(of: parsed)]
        } else if readType?.lowercased() == Self.clearReadTypeValue {
            command += ["--read-type", Self.clearReadTypeValue]
        }
        if confirm { command.append("--confirm") }
        return command
    }

    private func recordProvenance(
        change: FASTQPlatformLabelService.Change,
        inputs: [FileRecord],
        runClock: ProvenanceRunClock
    ) async throws {
        let command = replayCommand(bundleURL: change.bundleURL)
        // The record goes beside the metadata file only. Writing the bundle
        // root record would replace the import's record and prune the
        // bundle's per-file records, which hold how the reads were made.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-fastq-platform-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let explicit: [String: ParameterValue] = [
            "bundle": .file(change.bundleURL),
            "platform": change.platform.map { .string($0.rawValue) } ?? .null,
            "readType": change.readType.map { .string($0.rawValue) } ?? .null,
            "previousPlatform": change.previousPlatform.map { .string($0.rawValue) } ?? .null,
            "previousReadType": change.previousReadType.map { .string($0.rawValue) } ?? .null,
            "source": .string(change.source.rawValue),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq platform",
            parameters: explicit,
            toolName: "lungfish fastq platform",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputs,
            outputs: [ProvenanceRecorder.fileRecord(url: change.sidecarURL, format: .json, role: .output)],
            exitCode: 0,
            wallTime: runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: scratch
        )
    }

    private static func projectFolder(containing url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        while current.path != "/" {
            if ProjectRootTest.isProjectRoot(current) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    static func describe(_ report: FASTQPlatformLabelService.Report) -> String {
        let check = report.check
        var lines = [report.bundleURL.lastPathComponent]
        lines.append("  Recorded platform: \(check.recordedPlatform?.displayName ?? "none")")
        lines.append("  Recorded read type: \(check.recordedReadClass?.displayName ?? "none")")
        if let assignment = FASTQMetadataStore.load(for: report.fastqURL)?.platformAssignment {
            lines.append("  Decided: \(assignment.source.rawValue)")
        } else {
            lines.append("  Decided: before platform inference (no record)")
        }
        let inference = check.inference ?? PlatformInference.infer(fromFASTQ: report.fastqURL)
        lines.append("  Reads look like: \(inference.summary)")
        for line in inference.evidence { lines.append("    \(line)") }
        if check.isSuspect {
            lines.append("  Suspect label:")
            for reason in check.reasons { lines.append("    \(reason)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func printJSON(_ reports: [FASTQPlatformLabelService.Report]) {
        let rows = reports.map { report -> [String: Any] in
            let inference = report.check.inference ?? PlatformInference.infer(fromFASTQ: report.fastqURL)
            return [
                "bundle": report.bundleURL.path,
                "recordedPlatform": report.check.recordedPlatform?.rawValue ?? NSNull(),
                "recordedReadType": report.check.recordedReadClass?.rawValue ?? NSNull(),
                "verdict": report.check.verdict.rawValue,
                "inferredPlatform": inference.platform.rawValue,
                "inferredConfidence": inference.confidence.rawValue,
                "evidence": inference.evidence,
                "reasons": report.check.reasons,
            ]
        }
        printJSONObject(["bundles": rows])
    }

    private static func printJSONObject(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
