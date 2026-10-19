// ProvenanceReportExport.swift - The provenance report export that the app and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The provenance report export of File > Export > Provenance and the Inspector's export menu (Phase 2.12 lane 12.38,
/// ARCH ruling 1.1 row B9).
///
/// Both GUI entry points keep the pin gate sheet and the save panel for a folder. They then begin one Operations row
/// whose command is `lungfish-cli provenance export`, and the leaf writes the report folder and its record. The leaf
/// is the existing `ProvenanceCommand.ExportSubcommand`, whose contract row is `.text(reason: exportFormat)`, so the
/// runner runs it without `--format json` (``ViewerExportInvocation/emitsEvents`` is false) and completes the row on
/// exit 0.
public enum ProvenanceReportExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["provenance", "export"]
    /// The flag that names the report format. The leaf also reads `--format` and `-f` for it, which is why the
    /// runner never adds `--format json`.
    public static let exportFormatFlag = "--export-format"

    /// The leaf's invocation for one export, with absolute standardized paths. `allowUnpinned` is true only when the
    /// pin gate sheet's Export Anyway… answered for a script format, and it becomes the command's `--allow-unpinned`
    /// flag (ARCH ruling section 2, row B9).
    public static func invocation(
        inputURL: URL,
        format: ProvenanceExportFormat,
        outputDirectory: URL,
        allowUnpinned: Bool
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: inputURL.standardizedFileURL.path,
            leafArguments: [exportFormatFlag, format.cliToken] + (allowUnpinned ? [ProvenanceExporter.allowUnpinnedFlag] : []),
            output: outputDirectory.standardizedFileURL.path,
            force: false,
            emitsEvents: false
        )
    }

    /// The file `ProvenanceExporter.exportBundle` makes the primary artifact of `format`, which the completion alert
    /// names and Show in Finder reveals. Four formats keep the name ``ProvenanceExportFormat/defaultFilename`` gives,
    /// and the shell script and the methods text are the two it names differently. The parity class checks the result
    /// against the folder the leaf writes for every format.
    public static func primaryArtifactFileName(for format: ProvenanceExportFormat) -> String {
        switch format {
        case .shell: return "run.sh"
        case .methods: return "methods.md"
        case .python, .nextflow, .snakemake, .json: return format.defaultFilename
        }
    }
}
