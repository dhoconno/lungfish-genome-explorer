// ReferenceFASTAPanel.swift - Shared NSOpenPanel factory for reference FASTA/GenBank files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Shared NSOpenPanel factory for selecting reference FASTA/GenBank files.
public enum ReferenceFASTAPanel {
    @MainActor
    public static func make(title: String? = nil, message: String? = nil) -> NSOpenPanel {
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
}
