// MetadataExportSubcommand+Output.swift - lungfish-cli metadata export --output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension MetadataExportSubcommand {
    /// The invocation this parse stands for, which the record's argv comes from.
    func invocation() -> ViewerExportInvocation {
        FolderMetadataExport.invocation(
            folderURL: URL(fileURLWithPath: folderPath),
            selectionURL: selectionPath.map { URL(fileURLWithPath: $0) },
            outputURL: URL(fileURLWithPath: outputPath ?? ""),
            force: force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    /// `--output`. The shared leaf run exits 3 on a refusal, 64 on a failure and 125 on a cancel, and `--format json`
    /// then prints events as every viewer export leaf does. Standard output keeps its own path in `run()`.
    func runOutputExport() async throws {
        let command = self
        try await ViewerExportLeaf.run(
            globalOptions: globalOptions,
            startMessage: "Exporting the folder metadata."
        ) { _ in
            try command.export()
        }
    }

    /// The export, which refuses before it writes and writes payload and record in one transaction. The rows are the
    /// selection file's when `--selection` names one, and the folder's resolved metadata otherwise.
    func export() throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = invocation()
        let folderURL = URL(fileURLWithPath: invocation.input)
        let outputURL = URL(fileURLWithPath: invocation.output)
        guard globalOptions.outputFormat != .tsv else {
            throw ViewerExportRefusal(
                "--output writes CSV. Drop --format tsv, or print TSV to standard output without --output."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ViewerExportRefusal("No folder at \(folderURL.path). Pass the folder that holds the .lungfishfastq bundles.")
        }

        let selectionURL = invocation.selection.map { URL(fileURLWithPath: $0) }
        let samples: [FASTQSampleMetadata]
        let sourceURLs: [URL]
        if let selectionURL {
            guard FileManager.default.fileExists(atPath: selectionURL.path) else {
                throw ViewerExportRefusal(
                    "No selection file at \(selectionURL.path). Pass the file the app wrote for this export."
                )
            }
            let parsed: ViewerExportSelection
            do {
                parsed = try ViewerExportSelection.read(from: selectionURL)
            } catch {
                throw ViewerExportRefusal("The selection file at \(selectionURL.path) cannot be read. \(error)")
            }
            guard let rows = FolderMetadataExport.samples(in: parsed) else {
                throw ViewerExportRefusal(
                    "The selection file at \(selectionURL.path) holds a row that is not a sample. Export again from the app."
                )
            }
            samples = rows
            sourceURLs = [selectionURL]
        } else {
            let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)
            samples = resolved.sampleOrder.compactMap { resolved.samples[$0] }
            sourceURLs = FolderMetadataExport.sourceFiles(in: folderURL)
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: sourceURLs, force: invocation.force)

        let content = FolderMetadataExport.csv(samples: samples)
        var explicitOptions: [String: ParameterValue] = [
            "folder": .file(folderURL),
            "outputPath": .file(outputURL),
        ]
        if let selectionURL {
            explicitOptions["selection"] = .file(selectionURL)
        }
        if invocation.force {
            explicitOptions["force"] = .boolean(true)
        }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: FolderMetadataExport.workflowName,
            sourceURLs: sourceURLs,
            outputURL: outputURL,
            outputFormat: .text,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            resolved: ["sampleCount": .integer(samples.count)],
            runClock: runClock
        )) { stagedURL in
            try content.write(to: stagedURL, atomically: true, encoding: .utf8)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        let noun = samples.count == 1 ? "sample" : "samples"
        return ViewerExportLeafOutcome(
            outputURL: outputURL,
            message: "Exported \(samples.count) \(noun) to \(outputURL.lastPathComponent)"
        )
    }
}
