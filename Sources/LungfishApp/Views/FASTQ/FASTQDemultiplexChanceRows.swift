// FASTQDemultiplexChanceRows.swift - The Demultiplex Barcodes rows about the engine and chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// The engine's explanation, the caption of Exact Bare Barcode, and Keep Unchecked Samples, which shows exactly when
/// preflight can refuse the chosen kit as one the check for chance matches cannot judge (BIO-SATKIT-FLUIDIGM item 3).
/// The rows ask preflight again whenever a setting it reads changes. They sit in their own file because
/// `FASTQOperationToolPanes.swift` may not grow (file-size ratchet).
struct FASTQDemultiplexChanceRows: View {
    @Bindable var state: FASTQOperationDialogState
    /// The engine's explanation, which `FASTQOperationToolPanes.swift` keeps.
    let explanation: String

    var body: some View {
        Text(explanation).font(.caption).foregroundStyle(.secondary)
            .task(id: state.demultiplexChanceCheckSettings) { await state.refreshDemultiplexChanceCheck() }
        if let caption = state.demultiplexEngineChanceCaption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        if state.showsDemultiplexKeepUncheckedSamples {
            Toggle("Keep Unchecked Samples", isOn: $state.demultiplexChanceCheck.keepsUncheckedSamples)
            Text(FASTQOperationDialogState.demultiplexKeepUncheckedSamplesCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
