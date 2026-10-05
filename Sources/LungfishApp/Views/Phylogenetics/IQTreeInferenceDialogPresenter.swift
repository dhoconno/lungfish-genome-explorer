// IQTreeInferenceDialogPresenter.swift - IQ-TREE operation sheet presenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
struct IQTreeInferenceDialogPresenter {
    /// About 780x640 (D1). The form scrolls when the sheet is smaller.
    static let contentSize = NSSize(width: 780, height: 640)
    static let minimumContentSize = NSSize(width: 680, height: 480)

    static func present(
        from window: NSWindow,
        request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL,
        onRun: ((IQTreeInferenceDialogState) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let state = IQTreeInferenceDialogState(
            request: request,
            projectURL: projectURL
        )

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Build Tree with IQ-TREE"
        panel.isReleasedWhenClosed = false

        let dialog = IQTreeInferenceDialog(
            state: state,
            onCancel: {
                window.endSheet(panel)
                onCancel?()
            },
            onRun: {
                window.endSheet(panel)
                onRun?(state)
            }
        )

        let hostingController = NSHostingController(rootView: dialog)
        panel.contentViewController = hostingController
        panel.setContentSize(IQTreeInferenceDialogPresenter.contentSize)
        panel.contentMinSize = IQTreeInferenceDialogPresenter.minimumContentSize
        window.beginSheet(panel)
    }
}
