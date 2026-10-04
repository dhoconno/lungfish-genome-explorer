// FASTQOperationRowCommand.swift - The command a FASTQ operations dialog row shows after its run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the FASTQ operations dialog's Operations row records once its run has
/// succeeded and the final output paths are known.
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
/// Two kinds of run are refined.
/// - A derivative whose outputs are imported one bundle per output
///   (`.perInput` or `.fixedBatch`). Each imported bundle's manifest records
///   the command `FASTQOperationOutputImporter` built with the real input and
///   the final payload path (`operation.toolCommand`), and the row shows
///   those commands in import order.
/// - Savont. Its outputs are imported with the app's own import form, which no
///   `lungfish-cli` command is, so the manifest is no source. The row shows
///   the executed invocations instead, and each names the published FASTA in
///   `--output`.
///
/// A grouped result, such as a demultiplex, has no single manifest command,
/// and its executed invocations may name staging paths the run deletes. Every
/// other launch request (map, classify, assemble, pbAA and genotyping)
/// already records real paths at `begin`. Neither is refined.
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

    /// The refinement for a run. It reads the imported bundles' manifests and checks
    /// that every output exists, so a caller runs it off the main actor.
    nonisolated static func refinement(
        for result: FASTQOperationExecutionResult,
        fileManager: FileManager = .default
    ) -> Refinement {
        switch result.resolvedRequest {
        case .derivative(_, _, let outputMode):
            guard outputMode != .groupedResult, result.groupedContainerURL == nil else { return .notApplicable }
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

    /// `commands` as the row's command script when every line is a `lungfish-cli` command that
    /// names a final output, and a `keep` otherwise.
    nonisolated private static func checked(_ commands: [String]) -> Refinement {
        let lines = commands.flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
        let prefix = CLICommandIdentity.executableName + " "
        guard !lines.isEmpty,
              lines.allSatisfy({ $0.hasPrefix(prefix) && !$0.contains("<derived>") }) else {
            return .keep(reason: "a recorded command is not a lungfish-cli command that names its final output")
        }
        return .replace(with: commands.joined(separator: "\n"))
    }
}
