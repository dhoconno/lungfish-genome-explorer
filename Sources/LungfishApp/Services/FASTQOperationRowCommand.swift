// FASTQOperationRowCommand.swift - The command a FASTQ operations dialog row shows after its run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the FASTQ operations dialog's Operations row records once its run
/// has succeeded and the final output paths are known.
///
/// `MainSplitViewController.beginFASTQLaunchRequestOperation` records the
/// row's `lungfish-cli` command at `begin`, before the output exists, so a
/// derivative row shows `-o <derived>` and a Savont row shows
/// `--output <derived>`. docs/contracts/CLI-EQUIVALENCE.md lets a row replace
/// that command with `setCommand` for the same run, once it names outputs that
/// were resolved after `begin`. This type builds the replacement from the
/// structured result of the run and checks it, so a refinement never makes a
/// row worse. The `begin` command stays whenever a check fails.
///
/// Three kinds of run are refined.
/// - A derivative whose outputs are imported one bundle per output
///   (`.perInput` or `.fixedBatch`). Each imported bundle's manifest records
///   the command `FASTQOperationOutputImporter` built with the real input and
///   the final payload path (`operation.toolCommand`), and the row shows
///   those commands in import order.
/// - Demultiplex Barcodes. The dialog gives it the per-input mode, and the
///   execution service hands back its run folder as the one imported URL with
///   no grouped container, so it passes the guard on a grouped result below.
///   The run folder is no derived bundle and holds no manifest, which is why
///   every Demultiplex row of Walk 114 logged "records no command" and kept
///   `-o <derived>`. `lungfish-cli fastq demultiplex` writes the run's record
///   at the folder's root (`.lungfish-provenance.json`), and the record's
///   argv names the real input and the run folder in `--output`. The row shows
///   that argv, and the request tells a demultiplex apart, never the name of
///   a folder.
/// - Savont. Its outputs are imported with the app's own import form, which no
///   `lungfish-cli` command is, so the manifest is no source. The row shows
///   the executed invocations instead, and each names the published FASTA in
///   `--output`.
///
/// A result in the grouped mode has no single manifest command, and its
/// executed invocations may name staging paths the run deletes, so it is not
/// refined. A demultiplex never takes its command from the executed
/// invocations either, since they name the staged copy of the input. Every
/// other launch request (map, classify, assemble, pbAA and genotyping)
/// already records real paths at `begin`, and none of them is refined.
enum FASTQOperationRowCommand {
    /// What the row does after a successful run.
    enum Refinement: Sendable, Equatable {
        /// Replace the row's command with this one, a command script when the run made several outputs.
        case replace(with: String)
        /// Keep the command recorded at `begin`, and log `reason` once.
        case keep(reason: String)
        /// The run is not one this type refines. The row keeps its command and nothing is logged.
        case notApplicable
    }

    /// The command that replaces the row's, or nil when the `begin` command stays.
    nonisolated static func finalCommand(for result: FASTQOperationExecutionResult) -> String? {
        if case .replace(let command) = refinement(for: result) {
            return command
        }
        return nil
    }

    /// The refinement for a run. It reads the imported bundles' manifests or the run folder's record and
    /// checks that every output exists, so a caller runs it off the main actor.
    nonisolated static func refinement(
        for result: FASTQOperationExecutionResult,
        fileManager: FileManager = .default
    ) -> Refinement {
        switch result.resolvedRequest {
        case .derivative(let request, _, let outputMode):
            guard outputMode != .groupedResult, result.groupedContainerURL == nil else { return .notApplicable }
            // The request tells a demultiplex. A folder named `demultiplex-N` that a derivative imported is not one.
            if case .demultiplex = request {
                return demultiplexRefinement(runFolders: result.importedURLs)
            }
            return derivativeRefinement(importedURLs: result.importedURLs, fileManager: fileManager)
        case .savont:
            return savontRefinement(invocations: result.executedInvocations, fileManager: fileManager)
        default:
            return .notApplicable
        }
    }

    /// Applies a refinement to the row `id`: replaces its command, or logs once why it stays.
    @MainActor
    static func apply(
        _ refinement: Refinement,
        to id: UUID,
        reporter: any OperationReporting = OperationCenter.shared
    ) {
        switch refinement {
        case .replace(let command):
            reporter.setCommand(id: id, command: command)
        case .keep(let reason):
            reporter.log(id: id, level: .info, message: "The row keeps the command recorded at launch: \(reason)")
        case .notApplicable:
            break
        }
    }

    // MARK: - Derivative outputs

    nonisolated private static func derivativeRefinement(
        importedURLs: [URL],
        fileManager: FileManager
    ) -> Refinement {
        guard !importedURLs.isEmpty else { return .keep(reason: "the run imported no bundle") }
        var commands: [String] = []
        for bundleURL in importedURLs {
            guard fileManager.fileExists(atPath: bundleURL.path) else {
                return .keep(reason: "\(bundleURL.lastPathComponent) no longer exists")
            }
            guard let command = FASTQBundle.loadDerivedManifest(in: bundleURL)?.operation.toolCommand,
                  !command.isEmpty else {
                return .keep(reason: "\(bundleURL.lastPathComponent) records no command")
            }
            if !commands.contains(command) {
                commands.append(command)
            }
        }
        return checked(commands)
    }

    // MARK: - Demultiplex outputs

    /// The command a Demultiplex row shows, taken from the argv the run's own record holds. It reads the
    /// root record of each run folder (`.lungfish-provenance.json`) and no other file. A folder with no
    /// record, or a record with no argv, keeps the `begin` command, and a folder that is gone holds no record.
    nonisolated private static func demultiplexRefinement(runFolders: [URL]) -> Refinement {
        guard !runFolders.isEmpty else { return .keep(reason: "the run imported no folder") }
        var commands: [String] = []
        for folder in runFolders {
            guard let argv = ProvenanceRecorder.loadEnvelope(from: folder)?.argv, !argv.isEmpty else {
                return .keep(reason: "\(folder.lastPathComponent) holds no provenance record of its command")
            }
            let command = recordedCommandLine(argv: argv, projectRoot: ProjectTempDirectory.findProjectRoot(folder))
            if !commands.contains(command) {
                commands.append(command)
            }
        }
        // The dialog hands the CLI a staged copy of a virtual input and the run deletes the staging folder, so a
        // record that names one holds no input the person can run again. The row keeps its launch command.
        if commands.contains(where: { $0.contains("materialized-inputs-") }) {
            return .keep(reason: "the recorded command names a staged copy of the input, which the run deleted")
        }
        return checked(commands)
    }

    /// `argv` as the row spells a `lungfish-cli` command. The record's first word is the CLI as it was
    /// launched. An absolute path, or the `<external>/` form the writer gives one, shows as `lungfish-cli`.
    /// A record whose first word is no `lungfish-cli` is spelled as it stands, and `checked` keeps the row's command.
    nonisolated private static func recordedCommandLine(argv: [String], projectRoot: URL?) -> String {
        let words = argv.map { projectPath($0, projectRoot: projectRoot) }
        let cli = CLICommandIdentity.executableName
        guard let first = words.first,
              first == cli || (first.contains("/") && URL(fileURLWithPath: first).lastPathComponent == cli),
              words.count > 1,
              !words[1].contains(where: \.isWhitespace) else {
            return words.map(shellEscape).joined(separator: " ")
        }
        return FASTQOperationCLIInvocationBuilder.commandLine(
            for: FASTQCLIInvocation(subcommand: words[1], arguments: Array(words.dropFirst(2)))
        )
    }

    /// `word` with a leading `@/` (or one after `=`) spelled as a path under the project root. The CLI takes no
    /// `@/`, which only LGE's readers resolve. The record's reader does this for a record inside a project, so
    /// a word keeps `@/` only when no project was found, and then `checked` keeps the row's command.
    nonisolated private static func projectPath(_ word: String, projectRoot: URL?) -> String {
        guard let projectRoot else { return word }
        let marker = PortablePath.projectPrefix
        if word.hasPrefix(marker) {
            return projectRoot.appendingPathComponent(String(word.dropFirst(marker.count))).path
        }
        if let range = word.range(of: "=" + marker) {
            let relative = String(word[range.upperBound...])
            return String(word[..<range.lowerBound]) + "=" + projectRoot.appendingPathComponent(relative).path
        }
        return word
    }

    // MARK: - Savont outputs

    nonisolated private static func savontRefinement(
        invocations: [FASTQCLIInvocation],
        fileManager: FileManager
    ) -> Refinement {
        guard !invocations.isEmpty else { return .keep(reason: "the run executed no command") }
        var commands: [String] = []
        for invocation in invocations {
            guard let flag = invocation.arguments.firstIndex(of: "--output"),
                  invocation.arguments.indices.contains(flag + 1) else {
                return .keep(reason: "an executed command names no output")
            }
            let published = invocation.arguments[flag + 1]
            guard fileManager.fileExists(atPath: published) else {
                return .keep(reason: "the published FASTA \(URL(fileURLWithPath: published).lastPathComponent) no longer exists")
            }
            let command = FASTQOperationCLIInvocationBuilder.commandLine(for: invocation)
            if !commands.contains(command) {
                commands.append(command)
            }
        }
        return checked(commands)
    }

    // MARK: - The safety rule

    /// The forms a record keeps for a path it does not spell in full. The CLI takes none of them.
    nonisolated private static let placeholderPaths: [String] = [PortablePath.projectPrefix] + [
        PortablePath.bundlePlaceholder, PortablePath.workspacePlaceholder, PortablePath.toolRootPlaceholder,
        PortablePath.storageRootPlaceholder, PortablePath.externalPlaceholder,
    ].map { $0 + "/" }

    /// `commands` as the row's command script when every line is a `lungfish-cli` command that
    /// names a final output, and a `keep` otherwise. A line that still holds a placeholder path
    /// names no final output.
    nonisolated private static func checked(_ commands: [String]) -> Refinement {
        let lines = commands.flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
        let prefix = CLICommandIdentity.executableName + " "
        guard !lines.isEmpty,
              lines.allSatisfy({ line in
                  line.hasPrefix(prefix) && !line.contains("<derived>")
                      && !placeholderPaths.contains(where: { line.contains($0) })
              }) else {
            return .keep(reason: "a recorded command is not a lungfish-cli command that names its final output")
        }
        return .replace(with: commands.joined(separator: "\n"))
    }
}
