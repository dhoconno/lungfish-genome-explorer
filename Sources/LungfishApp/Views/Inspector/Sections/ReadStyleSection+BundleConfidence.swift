// ReadStyleSection+BundleConfidence.swift - The Minimum alignment confidence follows the bundle it was set on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// W-27 of the 3.2 session 1 walk (ALIGN-CONFIDENCE-CARRY). A confidence of 30 set on one reference stayed 30 on the next bundle
// that opened, and only the Inspector showed the filter. The block cannot reset in `clear()`, because the Inspector clears it on
// every selection, a second selection of the same reference row included, and REFMAP's rule is that a filter a person set in the
// Inspector stays then (`ReferenceBundleReadFilterSameRowTests`). So the block remembers which bundle it last loaded and resets
// the confidence only when a different bundle loads.

import Foundation

extension ReadStyleSectionViewModel {
    /// Called as a reference bundle loads into the block, before anything is read from it. A bundle other than the one the block
    /// last loaded starts at the default confidence. The same bundle keeps the value the person set.
    func resetConfidenceUnlessSameBundle(at bundleURL: URL) {
        let loaded = bundleURL.standardizedFileURL
        if confidenceBundleURL != loaded { minMapQ = 0 }
        confidenceBundleURL = loaded
    }

    /// Called as detached classifier evidence takes the block. The evidence has no bundle of its own, so it starts at the default,
    /// and the next reference bundle that loads is a different one from the last.
    func resetConfidenceForClassifierEvidence() {
        minMapQ = 0
        confidenceBundleURL = nil
    }
}
