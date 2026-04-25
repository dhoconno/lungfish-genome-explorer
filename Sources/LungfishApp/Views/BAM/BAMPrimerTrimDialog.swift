// BAMPrimerTrimDialog.swift - Dialog frame for the BAM primer-trim operation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import Observation

/// Primer-trim BAM dialog; pairs the inner tool panes with Cancel/Run buttons
/// wired to default-action keyboard shortcuts.
struct BAMPrimerTrimDialog: View {
    @Bindable var state: BAMPrimerTrimDialogState
    let onCancel: () -> Void
    let onRun: () -> Void
    let onBrowseScheme: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BAMPrimerTrimToolPanes(state: state, onBrowseScheme: onBrowseScheme)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isRunEnabled)
            }
            .padding()
        }
    }
}
