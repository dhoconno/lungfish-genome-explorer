// BAMPrimerTrimDialogPresenter.swift - Sheet presenter for the BAM primer-trim dialog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishIO

/// Presents ``BAMPrimerTrimDialog`` as a titled `NSPanel` sheet on an
/// existing `NSWindow`, mirroring ``BAMVariantCallingDialogPresenter``.
@MainActor
struct BAMPrimerTrimDialogPresenter {
    /// Presents the primer-trim dialog as a sheet. Invokes `onRun` or `onCancel` after the sheet ends.
    static func present(
        from window: NSWindow,
        bundle: ReferenceBundle,
        builtInSchemes: [PrimerSchemeBundle],
        projectSchemes: [PrimerSchemeBundle],
        availability: DatasetOperationAvailability,
        onRun: ((BAMPrimerTrimDialogState) -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onBrowseScheme: (() -> Void)? = nil
    ) {
        let state = BAMPrimerTrimDialogState(
            bundle: bundle,
            availability: availability,
            builtInSchemes: builtInSchemes,
            projectSchemes: projectSchemes
        )

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Primer-trim BAM"
        panel.isReleasedWhenClosed = false

        let dialog = BAMPrimerTrimDialog(
            state: state,
            onCancel: {
                window.endSheet(panel)
                onCancel?()
            },
            onRun: {
                window.endSheet(panel)
                onRun?(state)
            },
            onBrowseScheme: { onBrowseScheme?() }
        )

        let hostingController = NSHostingController(rootView: dialog)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 540, height: 480))
        window.beginSheet(panel)
    }
}
