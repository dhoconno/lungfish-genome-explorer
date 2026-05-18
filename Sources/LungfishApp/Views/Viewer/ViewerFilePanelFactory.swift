// ViewerFilePanelFactory.swift - viewer and drawer panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

@MainActor
enum ViewerFilePanelFactory {
    static func tableExportPanel(
        title: String,
        suggestedName: String,
        contentType: UTType
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        return panel
    }

    static func bookmarkedVariantsExportPanel() -> NSSavePanel {
        tableExportPanel(
            title: "Export Bookmarked Variants",
            suggestedName: "bookmarked_variants.tsv",
            contentType: .tabSeparatedText
        )
    }

    static func sequenceFastaExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = suggestedName
        panel.title = "Export Sequence"
        return panel
    }

    static func fastqOrientReferencePanel() -> NSOpenPanel {
        let panel = MappingWorkflowFilePanelFactory.referenceFASTAPanel(
            message: "Select a reference FASTA for read orientation"
        )
        return panel
    }

    static func fastqMetadataImportPanel(prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel
    }

    static func fastqMetadataExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedName
        return panel
    }

    static func sampleMetadataTemplatePanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "Save Sample Metadata Template"
        panel.prompt = "Save Template"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
        ]
        return panel
    }

    static func variantSampleMetadataImportPanel() -> NSOpenPanel {
        FeatureFilePanelFactory.variantSampleMetadataImportPanel()
    }

    static func phylogeneticSubtreeExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedName
        return panel
    }
}
