// GenotypeExportManualDefinitionsSubcommand.swift - lungfish-cli genotype export-manual-definitions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Writes the manual haplotype definitions the genotype viewer exports, with its record beside it (Phase 2.12 lane
/// 12.35, ARCH ruling 1.1 row A14).
///
/// The open store can hold assignments its saved sidecar lacks (BIO answer to Q-A3), so the leaf reads the
/// assignments from the selection file the app wrote and never from the bundle. It names that one file as its input
/// (BIO 6), and the bundle stands in the argv and the options. The app's Export runs this leaf behind its Operations
/// row.
struct GenotypeExportManualDefinitionsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-manual-definitions",
        abstract: "Write a genotype bundle's manual haplotype definitions as JSON with provenance"
    )

    @Argument(help: "The .lungfishgenotype bundle the assignments belong to")
    var bundlePath: String

    @OptionGroup var selection: ViewerExportOptions.Selection
    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> ViewerExportInvocation {
        GenotypeManualDefinitionsExport.invocation(
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            selectionURL: URL(fileURLWithPath: selection.path),
            outputURL: URL(fileURLWithPath: output.path),
            force: output.force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    func run() async throws {
        let command = self
        try await ViewerExportLeaf.run(
            globalOptions: globalOptions,
            startMessage: "Exporting manual haplotype definitions."
        ) { _ in
            try command.export()
        }
    }

    /// The export, which refuses before it writes and writes payload and record in one transaction.
    func export() throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let bundleURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
        let selectionURL = URL(fileURLWithPath: invocation.selection ?? selection.path)
        let outputURL = URL(fileURLWithPath: invocation.output)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ViewerExportRefusal(
                "No genotype bundle at \(bundleURL.path). Pass the .lungfishgenotype bundle the assignments belong to."
            )
        }
        guard FileManager.default.fileExists(atPath: selectionURL.path) else {
            throw ViewerExportRefusal(
                "No selection file at \(selectionURL.path). Pass the selection.json the app wrote beside the output."
            )
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: [selectionURL], force: invocation.force)

        let assignments: [ManualHaplotypeAssignment]
        do {
            assignments = try GenotypeManualDefinitionsExport.assignments(from: ViewerExportSelection.read(from: selectionURL))
        } catch {
            throw ViewerExportRefusal(
                "The selection file at \(selectionURL.path) holds no manual haplotype assignments this build reads. "
                    + error.localizedDescription
            )
        }
        let current = GenotypeManualDefinitionsExport.currentAssignments(assignments)
        let payload = try GenotypeManualDefinitionsExport.payload(currentAssignments: current)

        var explicitOptions: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "output": .file(outputURL),
            "selection": .file(selectionURL),
        ]
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: GenotypeManualDefinitionsExport.workflowName,
            sourceURLs: [selectionURL],
            outputURL: outputURL,
            outputFormat: .json,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            defaults: ["format": .string("json")],
            resolved: ["assignmentCount": .integer(current.count)],
            runClock: runClock
        )) { stagedURL in
            try payload.write(to: stagedURL, options: .atomic)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        let noun = current.count == 1 ? "assignment" : "assignments"
        return ViewerExportLeafOutcome(
            outputURL: outputURL,
            message: "Exported \(current.count) manual haplotype \(noun) to \(outputURL.lastPathComponent)"
        )
    }
}
