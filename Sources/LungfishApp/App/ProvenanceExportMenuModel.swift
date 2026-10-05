// ProvenanceExportMenuModel.swift - File > Export > Provenance menu items
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

@MainActor
enum ProvenanceExportMenuModel {
    struct Item: Equatable {
        let title: String
        let format: ProvenanceExportFormat
        let action: Selector
        let accessibilityIdentifier: String
    }

    static let items: [Item] = [
        Item(
            title: "Shell Script\u{2026}",
            format: .shell,
            action: #selector(FileMenuActions.exportProvenanceShell(_:)),
            accessibilityIdentifier: "file-menu-export-provenance-shell"
        ),
        Item(
            title: "Python Script\u{2026}",
            format: .python,
            action: #selector(FileMenuActions.exportProvenancePython(_:)),
            accessibilityIdentifier: "file-menu-export-provenance-python"
        ),
        Item(
            title: "Nextflow Pipeline\u{2026}",
            format: .nextflow,
            action: #selector(FileMenuActions.exportProvenanceNextflow(_:)),
            accessibilityIdentifier: "file-menu-export-provenance-nextflow"
        ),
        Item(
            title: "Snakemake Workflow\u{2026}",
            format: .snakemake,
            action: #selector(FileMenuActions.exportProvenanceSnakemake(_:)),
            accessibilityIdentifier: "file-menu-export-provenance-snakemake"
        ),
        Item(
            title: "Methods Section\u{2026}",
            format: .methods,
            action: #selector(FileMenuActions.exportProvenanceMethods(_:)),
            accessibilityIdentifier: "file-menu-export-provenance-methods"
        ),
        Item(
            title: "Full Provenance (JSON)\u{2026}",
            format: .json,
            action: #selector(FileMenuActions.exportProvenanceJSON(_:)),
            accessibilityIdentifier: "file-menu-export-provenance-json"
        ),
    ]
}
