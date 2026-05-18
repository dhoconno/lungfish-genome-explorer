// ImportFilePanelFactory.swift - import center and import service panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

@MainActor
enum ImportFilePanelFactory {
    static func projectImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.message = "Select files to import into the project"
        panel.prompt = "Import"
        return panel
    }

    static func importCenterPanel(
        configuration: ImportCardInfo.OpenPanelConfiguration,
        message: String
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = configuration.canChooseFiles
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection
        panel.allowsOtherFileTypes = configuration.allowsOtherFileTypes
        if let allowedTypes = configuration.allowedTypes {
            panel.allowedContentTypes = allowedTypes
        }
        panel.message = message
        return panel
    }

    static func primerSchemeFilePanel(extensions: [String]) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel
    }
}
