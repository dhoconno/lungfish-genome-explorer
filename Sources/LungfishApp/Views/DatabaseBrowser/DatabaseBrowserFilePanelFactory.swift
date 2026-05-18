// DatabaseBrowserFilePanelFactory.swift - Database Browser panel configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

@MainActor
enum DatabaseBrowserFilePanelFactory {
    static func accessionListImportPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Import Accession List"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .plainText,
        ]
        return panel
    }
}
