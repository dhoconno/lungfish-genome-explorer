// SavePanelPresenting.swift — Test seams for presenting save panels and writing the pasteboard
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

// MARK: - Test-seam protocol

/// Test seam for presenting an `NSSavePanel`.
@MainActor
public protocol SavePanelPresenting {
    func present(suggestedName: String, on window: NSWindow) async -> URL?
}

// MARK: - Default implementations

@MainActor
public struct DefaultSavePanelPresenter: SavePanelPresenting {
    public init() {}

    public func present(suggestedName: String, on window: NSWindow) async -> URL? {
        let panel = MetagenomicsFilePanelFactory.readExtractionSavePanel(suggestedName: suggestedName)
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

@MainActor
public struct DefaultPasteboard: PasteboardWriting {
    public init() {}

    public func setString(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
