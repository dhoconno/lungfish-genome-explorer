// FeatureFilePanelFactory.swift - shared file panel configuration for feature views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

@MainActor
enum FeatureFilePanelFactory {
    static func inspectorProvenanceExportPanel(defaultDirectoryName: String) -> NSSavePanel {
        AppFilePanelFactory.provenanceExportPanel(defaultDirectoryName: defaultDirectoryName)
    }

    static func inspectorTextMetadataImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Select a CSV or TSV file with sample metadata"
        return panel
    }

    static func variantSampleMetadataImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
            .init(filenameExtension: "txt")!,
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a TSV or CSV file with sample metadata"
        panel.prompt = "Import"
        return panel
    }

    static func attachmentImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel
    }

    static func primerSchemeFolderPanel(directoryURL: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose Primer Scheme"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.directoryURL = directoryURL
        return panel
    }

    static func metadataCSVImportPanel(message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = message
        return panel
    }

    static func metadataCSVExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        return panel
    }
}
