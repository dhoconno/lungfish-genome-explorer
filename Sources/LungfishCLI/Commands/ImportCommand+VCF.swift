// ImportCommand+VCF.swift - import vcf into a reference bundle, with events, the cancel and the two finishing modes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// `import vcf <vcf> --output-dir <bundle.lungfishref>` attaches the variants to the bundle as `variants/<track>.db`
/// through `VCFBundleVariantImport`, the import the Import Center runs (Phase 2.12 lane 12.07, A64, plan decision
/// C4 of 2.11). With `--format json` the run prints the row's events. SIGTERM, the app's Cancel, cancels the import,
/// removes its private staging folder, records the run as cancelled in the project and exits 125 (decision S7).
///
/// `--resume` and `--materialize` replace the two finishing modes that the app executable ran for the Import Center. Each
/// finishes the import of the `--replace` track from the database it already has, on a private copy, then
/// reconciles the chromosome names, finalizes and publishes the track as a fresh import does.
extension ImportCommand.VCFSubcommand {
    /// How the attach builds the track's database.
    enum AttachMode: String, Sendable {
        /// Read the VCF into a new database.
        case fresh
        /// Build the indexes of the `--replace` track's database, whose import stopped at `import_state = indexing`.
        case resume
        /// Fill the INFO table of the `--replace` track's database, whose materialization was skipped or stopped.
        case materialize
    }

    /// Why a finishing mode refused the track it was given. The command exits with the input error.
    struct AttachRefusal: LocalizedError {
        let errorDescription: String?
    }

    var attachMode: AttachMode {
        resume ? .resume : (materialize ? .materialize : .fresh)
    }

    /// Attaches `inputURL` to an existing bundle's variant database as `variants/<track>.db`, updates the
    /// manifest's variant tracks and writes `variants/<track>.lungfish-provenance.json`.
    func runAttachToExistingBundle(
        inputURL: URL,
        bundleURL: URL,
        formatter: TerminalFormatter,
        emitter: ImportCLIEventEmitter,
        eventsOn: Bool,
        runClock: ProvenanceRunClock
    ) async throws {
        let profile = importProfile ?? .auto
        let mode = attachMode
        printHumanLine(formatter.header("VCF Import"), eventsOn: eventsOn)
        printHumanLine("", eventsOn: eventsOn)
        printHumanLine(formatter.keyValueTable([
            ("Input", inputURL.lastPathComponent),
            ("Bundle", bundleURL.path),
            ("Import profile", profile.rawValue),
        ] + (mode == .fresh ? [] : [("Mode", mode.rawValue)])), eventsOn: eventsOn)
        printHumanLine("", eventsOn: eventsOn)

        let quiet = globalOptions.quiet
        let command = vcfAttachCommand(inputURL: inputURL, bundleURL: bundleURL)
        let request = VCFBundleVariantImport.Request(
            vcfURL: inputURL, bundleURL: bundleURL, trackName: name, importProfile: profile, replaceTrackID: replace
        )
        let staging = bundleURL.appendingPathComponent("variants/.import-\(request.operationID.uuidString)", isDirectory: true)
        let outcome = await ImportCancellation.run { () async throws -> AttachSummary in
            try await ImportCancellation.blocking {
                try Self.attach(
                    request,
                    mode: mode,
                    progressHandler: { fraction, message in
                        emitter.emitProgress(max(0.0, min(1.0, fraction)), message: message)
                        if !quiet, !eventsOn { print(formatter.info(message)) }
                    },
                    shouldCancel: { SIGTERMCancellation.signalCaught },
                    makeProvenance: { facts in
                        try Self.vcfAttachProvenance(facts: facts, mode: mode, command: command, runClock: runClock)
                    }
                )
            }
        }

        switch outcome {
        case .success(let result):
            if let warning = result.cleanupWarning {
                if eventsOn { emitter.emitWarning(warning) } else { print(formatter.warning(warning)) }
            }
            emitter.emitComplete(attachedTo: bundleURL, message: "\(result.variantCount) variants imported")
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.header("Summary"), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.keyValueTable([
                ("Track ID", result.trackInfo.id),
                ("Track name", result.trackInfo.name),
                ("Variants", formatNumber(Int64(result.variantCount))),
                ("Database", result.trackInfo.databasePath ?? ""),
                ("Renamed chromosomes", String(result.renamedChromosomes)),
            ]), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(
                formatter.success("VCF import complete: attached '\(result.trackInfo.name)' to \(bundleURL.lastPathComponent)"),
                eventsOn: eventsOn
            )
        case .failure(let error) where error is CancellationError:
            // The worker removes the staging folder at its next cancel check. A worker held in a step that does
            // not check gets 4 seconds, then the folder is removed here, inside the app's 6 second grace.
            _ = await Self.waitUntilGone(staging, seconds: 4)
            try? FileManager.default.removeItem(at: staging)
            throw await ImportCancellation.finish(
                emitter: emitter,
                command: "import vcf",
                parameters: ["input": .file(inputURL), "bundle": .file(bundleURL)],
                recordDirectory: ProjectTempDirectory.findProjectRoot(bundleURL) ?? bundleURL.deletingLastPathComponent(),
                startedAt: runClock.startedAt
            )
        case .failure(let error) where error is VCFBundleVariantImport.Error || error is AttachRefusal:
            // `--replace` named a track the bundle does not have, or a finishing mode a database it cannot finish:
            // a usage error, not a failed import.
            reportVCFFailure(error.localizedDescription, formatter: formatter, emitter: emitter, eventsOn: eventsOn)
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            reportVCFFailure("VCF attach failed: \(error.localizedDescription)", formatter: formatter, emitter: emitter, eventsOn: eventsOn)
            throw CLIExitCode.failure.exitCode
        }
    }

    /// Tells the person, or the app's row, why the import stopped.
    func reportVCFFailure(_ message: String, formatter: TerminalFormatter, emitter: ImportCLIEventEmitter, eventsOn: Bool) {
        if eventsOn {
            emitter.emitFailed(message)
        } else {
            print(formatter.error(message))
        }
    }

    func vcfAttachCommand(inputURL: URL, bundleURL: URL) -> [String] {
        var command = [CLICommandIdentity.executableName, "import", "vcf", inputURL.path, "--output-dir", bundleURL.path]
        if let name { command += ["--name", name] }
        if let importProfile { command += ["--import-profile", importProfile.rawValue] }
        if let replace { command += ["--replace", replace] }
        if resume { command.append("--resume") }
        if materialize { command.append("--materialize") }
        if globalOptions.quiet { command.append("--quiet") }
        if globalOptions.noColor { command.append("--no-color") }
        return command
    }

    private static func waitUntilGone(_ url: URL, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
