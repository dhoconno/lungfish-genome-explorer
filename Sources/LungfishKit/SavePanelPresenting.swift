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

    /// Presents the panel opened in `folder`, or where the system last left it when `folder` is nil.
    func present(suggestedName: String, on window: NSWindow, startingIn folder: URL?) async -> URL?
}

public extension SavePanelPresenting {
    /// A presenter that knows no starting folder ignores it.
    func present(suggestedName: String, on window: NSWindow, startingIn folder: URL?) async -> URL? {
        await present(suggestedName: suggestedName, on: window)
    }
}

// MARK: - Default implementations

@MainActor
public struct DefaultSavePanelPresenter: SavePanelPresenting {
    public init() {}

    public func present(suggestedName: String, on window: NSWindow) async -> URL? {
        await present(suggestedName: suggestedName, on: window, startingIn: nil)
    }

    public func present(suggestedName: String, on window: NSWindow, startingIn folder: URL?) async -> URL? {
        let panel = MetagenomicsFilePanelFactory.readExtractionSavePanel(suggestedName: suggestedName, startingIn: folder)
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
