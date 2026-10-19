// ProvenanceExportFrozenWriter.swift - The in-process provenance report export as the app made it at the 12.38 base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Side A of ProvenanceExportCLIGUIParityReplayTests. Both GUI entry points (File > Export > Provenance and the
// Inspector's export menu) wrote the report folder in process at aea620334 with `ProvenanceExportRequest.write`, which
// called `ProvenanceExporter.exportBundle` with the record the entry point had resolved and the argv
// `AppProvenanceExportCommandBuilder.argv` built, then `--allow-unpinned` after Export Anyway…. The lane deleted
// `write`, `exportArgv` and the builder, so this file keeps their bodies. The exporter has no signing provider here,
// as in the pin gate tests, so the folder does not depend on a key of the machine.

import Foundation
import LungfishCore
import LungfishWorkflow

enum ProvenanceExportFrozenWriter {
    /// The command the in-process write recorded, in the order of the base's builder.
    static func argv(selectedURL: URL, format: ProvenanceExportFormat, outputDirectory: URL, allowUnpinned: Bool) -> [String] {
        [
            CLICommandIdentity.executableName, "provenance", "export", selectedURL.path,
            "--export-format", format.cliToken, "--output", outputDirectory.path,
        ] + (allowUnpinned ? [ProvenanceExporter.allowUnpinnedFlag] : [])
    }

    /// Resolves the record of `selectedURL` as the Inspector's finder does, then writes the report folder.
    static func write(
        selectedURL: URL,
        format: ProvenanceExportFormat,
        outputDirectory: URL,
        allowUnpinned: Bool
    ) throws -> ProvenanceExportBundle {
        guard let found = ProvenanceRecorder.findProvenanceReading(for: selectedURL) else {
            throw ProvenanceError.exportFailed("No provenance record for \(selectedURL.path)")
        }
        return try ProvenanceExporter(signingProvider: nil).exportBundle(
            found.reading.envelope,
            format: format,
            to: outputDirectory,
            sourceSidecarURL: found.sidecarURL,
            sourceRootURL: selectedURL,
            exportArgv: argv(selectedURL: selectedURL, format: format, outputDirectory: outputDirectory, allowUnpinned: allowUnpinned),
            allowUnpinned: allowUnpinned
        )
    }
}
