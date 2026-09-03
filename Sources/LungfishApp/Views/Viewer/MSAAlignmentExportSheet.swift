// MSAAlignmentExportSheet.swift - Destination and format sheet for alignment export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit

/// Where an exported alignment goes. Labels and button titles deliberately
/// match ``ClassifierExtractionDialog`` so the two sheets read as one idiom.
enum MSAExportDestination: String, CaseIterable, Identifiable {
    case bundle
    case file
    case clipboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bundle: return "Save as Bundle"
        case .file: return "Save to File…"
        case .clipboard: return "Copy to Clipboard"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .bundle: return "Create Bundle"
        case .file: return "Save"
        case .clipboard: return "Copy"
        }
    }
}

/// Whether the export keeps alignment gaps. This is the choice that changes
/// what the exported object *is*: an alignment, or a set of sequences.
enum MSAExportLayout: String, CaseIterable, Identifiable {
    case aligned
    case unaligned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aligned: return "Aligned FASTA (keep gaps)"
        case .unaligned: return "Unaligned FASTA (remove gaps)"
        }
    }

    /// The bundle kind this layout produces. Gapped residues in a reference
    /// bundle would be a data defect, so aligned stays a `.lungfishmsa`.
    var bundleOutputKind: String {
        switch self {
        case .aligned: return "msa"
        case .unaligned: return "reference"
        }
    }

    var bundleCaption: String {
        switch self {
        case .aligned:
            return "Creates a .lungfishmsa alignment bundle with gaps preserved. Its consensus and variable sites describe the exported subset, not the parent."
        case .unaligned:
            return "Creates a .lungfishref reference bundle holding the sequences with gaps removed."
        }
    }
}

/// Whether the export covers the whole alignment or only the current selection.
enum MSAExportScope: String, CaseIterable, Identifiable {
    case entireAlignment
    case selectedRows

    var id: String { rawValue }
}

struct MSAAlignmentExportConfiguration {
    let destination: MSAExportDestination
    let layout: MSAExportLayout
    let format: String
    let scope: MSAExportScope
    let name: String
}

enum MSAAlignmentExportSheet {
    /// Formats `msa export` accepts. The file destination offers all of them;
    /// hiding formats the CLI already ships would be a parity regression, and
    /// PHYLIP and NEXUS are what tree builders consume.
    static let alignedFileFormats = ["aligned-fasta", "phylip", "nexus", "clustal", "stockholm", "a2m", "a3m"]

    /// The clipboard cap. Gapped output is roughly rows times aligned length,
    /// so this binds sooner than users expect.
    static let clipboardByteCap = 5 * 1024 * 1024

    static func isClipboardAvailable(estimatedBytes: Int) -> Bool {
        estimatedBytes <= clipboardByteCap
    }

    static func clipboardUnavailableMessage(estimatedBytes: Int) -> String {
        let megabytes = max(1, estimatedBytes / 1_048_576)
        return "This alignment is about \(megabytes) MB, too large for the clipboard. Choose Save to File or Save as Bundle instead."
    }

    /// Maps a configuration onto the CLI. The bundle leg uses `msa extract`,
    /// whose `--output-kind` decides gapped versus ungapped; the file and
    /// clipboard legs use `msa export`, whose `--output-format` does.
    static func cliArguments(
        for configuration: MSAAlignmentExportConfiguration,
        bundleURL: URL,
        outputURL: URL,
        rows: String?,
        columns: String?
    ) -> [String] {
        let scopedRows = configuration.scope == .selectedRows ? rows : nil
        let scopedColumns = configuration.scope == .selectedRows ? columns : nil

        switch configuration.destination {
        case .bundle:
            return CLIMSAActionCommandBuilder.buildExtractArguments(
                bundleURL: bundleURL,
                outputURL: outputURL,
                outputKind: configuration.layout.bundleOutputKind,
                rows: scopedRows,
                columns: scopedColumns,
                name: configuration.name,
                force: true
            )
        case .file, .clipboard:
            return CLIMSAActionCommandBuilder.buildExportArguments(
                bundleURL: bundleURL,
                outputURL: outputURL,
                outputFormat: configuration.format,
                rows: scopedRows,
                columns: scopedColumns,
                force: true
            )
        }
    }
}
