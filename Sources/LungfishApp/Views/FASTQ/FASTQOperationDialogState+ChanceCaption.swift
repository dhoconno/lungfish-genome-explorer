// FASTQOperationDialogState+ChanceCaption.swift - The dialog's words and choices about chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The person's Keep Unchecked Samples in the Demultiplex Barcodes tool (DEMUX-FLOOR-SATURATED-KIT).
struct FASTQDemultiplexChanceCheck: Equatable {
    var keepsUncheckedSamples = false
}

extension FASTQOperationDialogState {
    /// The caption under the engine's explanation while Exact Bare Barcode is picked (DEMUX-EXACT-BARE-NO-FLOOR, ruling
    /// UX-EXACT-BARE-WORDS). It sits in this file because `FASTQOperationDialogState.swift` may not grow (file-size ratchet).
    static let demultiplexExactBareChanceCaption =
        "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in their sequence, such as reads whose index is only in the read names, it can make sample files from chance matches. Use it only on reads that carry the barcodes in their sequence."

    var demultiplexEngineChanceCaption: String? {
        demultiplexEngine == .exactBareBarcode ? Self.demultiplexExactBareChanceCaption : nil
    }

    /// True when the cutadapt engine will search the selected built-in kit as
    /// the platform's full adapter+barcode construct, so the Location picker
    /// and the 5'/3' Distance fields have no effect and are hidden.
    var demultiplexKitUsesPlatformConstruct: Bool {
        guard demultiplexEngine == .cutadapt,
              demultiplexBarcodeSource == .builtinKit,
              let kit = BarcodeKitRegistry.kit(byID: demultiplexKitID) else { return false }
        return kit.searchesFullPlatformConstruct
    }

    var showsDemultiplexKeepUncheckedSamples: Bool { false }

    var demultiplexKeepUncheckedSamplesForRun: Bool? { nil }

    func refreshDemultiplexChanceCheck() async {}
}
