// BAMPrimerTrimDialog.swift - Dialog frame for the BAM primer-trim operation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Observation

/// Primer-trim BAM dialog; pairs the inner tool panes with Cancel/Run buttons
/// wired to default-action keyboard shortcuts.
struct BAMPrimerTrimDialog: View {
    @Bindable var state: BAMPrimerTrimDialogState
    let onCancel: () -> Void
    let onRun: () -> Void
    let onBrowseScheme: () -> Void

    /// The sheet's default content size. Wide enough that the longest built-in
    /// default output name ("<track> • Primer-trimmed (QIAseq Direct SARS-CoV-2
    /// with Booster A)") shows whole beside its label; longer custom names
    /// scroll in the field.
    static let defaultSheetSize = NSSize(width: 720, height: 480)

    var body: some View {
        VStack(spacing: 0) {
            BAMPrimerTrimToolPanes(state: state, onBrowseScheme: onBrowseScheme)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run", action: handleRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isRunEnabled)
            }
            .padding()
        }
    }

    private func handleRun() {
        _ = state.prepareForRun()
        onRun()
    }
}
