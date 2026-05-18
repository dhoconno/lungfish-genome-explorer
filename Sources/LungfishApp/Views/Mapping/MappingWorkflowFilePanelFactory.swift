// MappingWorkflowFilePanelFactory.swift - mapping, reference, and workflow panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

@MainActor
enum MappingWorkflowFilePanelFactory {
    static func referenceFASTAPanel(title: String? = nil, message: String? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        if let title {
            panel.title = title
        }
        if let message {
            panel.message = message
        }
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel
    }

    static func gffAnnotationPanel(title: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel
    }

    static func workflowOpenPanel(contentTypes: [UTType]) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.message = "Select a Lungfish workflow bundle or workflow JSON file"
        return panel
    }

    static func workflowSavePanel(
        contentTypes: [UTType],
        suggestedName: String,
        message: String
    ) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = contentTypes
        panel.nameFieldStringValue = suggestedName
        panel.message = message
        return panel
    }

    static func nextflowExportPanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nf") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.message = "Export as Nextflow pipeline"
        return panel
    }

    static func snakemakeExportPanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Snakefile"
        panel.message = "Export as Snakemake workflow"
        return panel
    }
}
