// RecordingFilePreviewRenderer.swift - Test double for the viewer's embedded preview renderer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishApp

/// Stands in for `ViewerViewController.embeddedFilePreviewRenderer`.
///
/// Routing tests install it so a file the viewer sends to PDFKit or Quick Look
/// is recorded instead of drawn. It writes the status line a finished Quick
/// Look preview writes, so tests that read the status bar see what the app
/// shows after a successful preview.
@MainActor
final class RecordingFilePreviewRenderer {
    private(set) var renderedURLs: [URL] = []

    /// Creates a recorder and installs it on `viewer`.
    @discardableResult
    static func install(on viewer: ViewerViewController) -> RecordingFilePreviewRenderer {
        let recorder = RecordingFilePreviewRenderer()
        viewer.embeddedFilePreviewRenderer = { viewer, fileURL in
            recorder.renderedURLs.append(fileURL)
            viewer.statusBar.positionLabel.stringValue = "Previewing: \(fileURL.lastPathComponent)"
            viewer.statusBar.selectionLabel.stringValue = ""
        }
        return recorder
    }
}
