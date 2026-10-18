// MappingWorkflowFilePanelFactory.swift - mapping, reference, and workflow panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import UniformTypeIdentifiers

@MainActor
enum MappingWorkflowFilePanelFactory {
    static func referenceFASTAPanel(title: String? = nil, message: String? = nil) -> NSOpenPanel {
        ReferenceFASTAPanel.make(title: title, message: message)
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
        panel.message = "Select a Lungfish workflow bundle"
        return panel
    }
}
