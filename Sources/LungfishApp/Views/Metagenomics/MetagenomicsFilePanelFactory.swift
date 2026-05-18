// MetagenomicsFilePanelFactory.swift - metagenomics import/export panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

@MainActor
enum MetagenomicsFilePanelFactory {
    static func naoMgsResultsImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Select NAO-MGS Results"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data, .folder]
        panel.message = "Select a virus_hits_final.tsv.gz file or results directory"
        return panel
    }

    static func nvdResultsImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Select NVD Results Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the top-level NVD run directory"
        return panel
    }

    static func czIdExportImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Select CZ-ID Export"
        panel.message = "Select a CZ-ID taxon report TSV, ZIP archive, or extracted folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "zip") ?? .zip,
            UTType(filenameExtension: "tsv") ?? .tabSeparatedText,
            UTType(filenameExtension: "txt") ?? .plainText,
            UTType(filenameExtension: "csv") ?? .commaSeparatedText,
        ]
        panel.allowsOtherFileTypes = true
        return panel
    }

    static func tsvSummaryExportPanel(title: String, suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.title = title
        return panel
    }

    static func delimitedExportPanel(
        title: String? = nil,
        suggestedName: String,
        contentTypes: [UTType] = [.plainText]
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        if let title {
            panel.title = title
        }
        panel.allowedContentTypes = contentTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel
    }

    static func blastDelimitedExportPanel(fileExtension: String) -> NSSavePanel {
        let contentTypes: [UTType] = fileExtension == "csv"
            ? [.commaSeparatedText]
            : [.tabSeparatedText]
        return delimitedExportPanel(
            suggestedName: "blast_results.\(fileExtension)",
            contentTypes: contentTypes
        )
    }

    static func readExtractionSavePanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        return panel
    }
}
