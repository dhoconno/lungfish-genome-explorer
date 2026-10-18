// FastqExportSampleBarcodesSubcommand.swift - lungfish-cli fastq export sample-barcodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Writes the sample sheet the app's FASTQ metadata drawer exports, with its record beside it.
///
/// The rows may hold edits the drawer has not saved, so the app writes them to a selection file before the row
/// begins and this leaf reads only that file, which its record names as the one input with its digest (ARCH ruling
/// 1.3, BIO 6). The FASTQ file or bundle is the drawer's subject and is checked to exist, but the leaf never opens
/// it. `--tab samples` writes the full sheet. `--tab demux` writes the same sheet, or barcode ids alone when the
/// selection says the demux step is asymmetric. The app's Export runs this leaf behind its Operations row.
struct FastqExportSampleBarcodesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample-barcodes",
        abstract: "Write the sample barcode sheet of the FASTQ metadata drawer as CSV with provenance"
    )

    @Argument(help: "The FASTQ file or bundle the drawer shows")
    var bundlePath: String

    @OptionGroup var tab: ViewerExportOptions.Tab<FASTQSampleBarcodeTab>
    @OptionGroup var selection: ViewerExportOptions.Selection
    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> ViewerExportInvocation {
        FASTQSampleBarcodeExport.invocation(
            bundleURL: URL(fileURLWithPath: bundlePath),
            tab: tab.tab,
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
            startMessage: "Exporting the FASTQ sample sheet."
        ) { _ in
            try command.export()
        }
    }

    /// The export, which refuses before it writes and writes payload and record in one transaction.
    func export() throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let bundleURL = URL(fileURLWithPath: invocation.input)
        let selectionURL = URL(fileURLWithPath: invocation.selection ?? selection.path)
        let outputURL = URL(fileURLWithPath: invocation.output)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ViewerExportRefusal("No FASTQ file or bundle at \(bundleURL.path). Pass the one the drawer shows.")
        }
        guard FileManager.default.fileExists(atPath: selectionURL.path) else {
            throw ViewerExportRefusal("No selection file at \(selectionURL.path). Pass the file the app wrote for this export.")
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: [selectionURL], force: invocation.force)

        let parsed: ViewerExportSelection
        do {
            parsed = try ViewerExportSelection.read(from: selectionURL)
        } catch {
            throw ViewerExportRefusal("The selection file at \(selectionURL.path) cannot be read. \(error)")
        }
        guard let assignments = FASTQSampleBarcodeExport.assignments(in: parsed) else {
            throw ViewerExportRefusal(
                "The selection file at \(selectionURL.path) names a row with no sample id. Export again from the app."
            )
        }
        let asymmetric = FASTQSampleBarcodeExport.isAsymmetric(parsed)
        let content = FASTQSampleBarcodeExport.csv(assignments: assignments, tab: tab.tab, asymmetric: asymmetric)

        var explicitOptions: [String: ParameterValue] = [
            "outputPath": .file(outputURL),
            "tab": .string(tab.tab.rawValue),
            "selection": .file(selectionURL),
        ]
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: FASTQSampleBarcodeExport.workflowName,
            sourceURLs: [selectionURL],
            outputURL: outputURL,
            outputFormat: .text,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            resolved: [
                "assignmentCount": .integer(assignments.count),
                "asymmetricDemux": .boolean(asymmetric),
            ],
            runClock: runClock
        )) { stagedURL in
            try content.write(to: stagedURL, atomically: true, encoding: .utf8)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        let noun = assignments.count == 1 ? "sample" : "samples"
        return ViewerExportLeafOutcome(
            outputURL: outputURL,
            message: "Exported \(assignments.count) \(noun) to \(outputURL.lastPathComponent)"
        )
    }
}
