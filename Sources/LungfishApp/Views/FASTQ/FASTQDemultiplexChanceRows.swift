// FASTQDemultiplexChanceRows.swift - The Demultiplex Barcodes rows about chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// The caption of Exact Bare Barcode, and Keep Unchecked Samples, which shows exactly when preflight can refuse the chosen
/// kit as one the check for chance matches cannot judge (BIO-SATKIT-FLUIDIGM item 3), or an Exact Bare Barcode run as one
/// whose read names carry the kit's barcodes (DEMUX-EXACT-BARE-NO-FLOOR). The pane asks preflight again whenever a setting
/// it reads changes (the `.task` on its Engine row). The engine explanations are one click away behind the About engines
/// button (`FASTQDemultiplexHelp`). The rows sit in their own file because `FASTQOperationToolPanes.swift` may not grow
/// (file-size ratchet).
struct FASTQDemultiplexChanceRows: View {
    @Bindable var state: FASTQOperationDialogState

    var body: some View {
        if let caption = state.demultiplexEngineChanceCaption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        if state.showsDemultiplexKeepUncheckedSamples {
            Toggle("Keep Unchecked Samples", isOn: $state.demultiplexChanceCheck.keepsUncheckedSamples)
            Text(state.demultiplexKeepUncheckedSamplesCaptionForEngine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
