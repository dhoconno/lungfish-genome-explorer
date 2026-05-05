// IQTreeInferenceDialogPresenter.swift - IQ-TREE operation sheet presenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
struct IQTreeInferenceDialogPresenter {
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
            styleMask: [.titled],
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
        panel.setContentSize(NSSize(width: 980, height: 700))
        window.beginSheet(panel)
    }
}
