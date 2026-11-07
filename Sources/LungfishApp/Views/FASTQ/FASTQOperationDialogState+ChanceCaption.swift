// FASTQOperationDialogState+ChanceCaption.swift - The dialog's caption for Exact Bare Barcode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension FASTQOperationDialogState {
    /// The caption under the engine's explanation while Exact Bare Barcode is picked (DEMUX-EXACT-BARE-NO-FLOOR, ruling
    /// UX-EXACT-BARE-WORDS). It sits in this file because `FASTQOperationDialogState.swift` may not grow (file-size ratchet).
    static let demultiplexExactBareChanceCaption = ""

    var demultiplexEngineChanceCaption: String? {
        nil
    }
}
