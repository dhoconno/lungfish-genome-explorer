// FASTQOperationDialogState+ChanceCaption.swift - The dialog's caption for Exact Bare Barcode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension FASTQOperationDialogState {
    /// The caption under the engine's explanation while Exact Bare Barcode is picked (DEMUX-EXACT-BARE-NO-FLOOR, ruling
    /// UX-EXACT-BARE-WORDS). It sits in this file because `FASTQOperationDialogState.swift` may not grow (file-size ratchet).
    static let demultiplexExactBareChanceCaption =
        "Exact Bare Barcode does not check for chance matches. On reads that do not carry the chosen barcodes in their sequence, such as reads whose index is only in the read names, it can make sample files from chance matches. Use it only on reads that carry the barcodes in their sequence."

    var demultiplexEngineChanceCaption: String? {
        demultiplexEngine == .exactBareBarcode ? Self.demultiplexExactBareChanceCaption : nil
    }
}
