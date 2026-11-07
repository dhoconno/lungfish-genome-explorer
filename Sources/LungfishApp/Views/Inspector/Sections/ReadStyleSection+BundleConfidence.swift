// ReadStyleSection+BundleConfidence.swift - The depth filters and the consensus settings follow the bundle they were set on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// W-27 of the 3.2 session 1 walk (ALIGN-CONFIDENCE-CARRY). A confidence of 30 set on one reference stayed 30 on the next bundle
// that opened, and only the Inspector showed the filter. The block cannot reset in `clear()`, because the Inspector clears it on
// every selection, a second selection of the same reference row included, and REFMAP's rule is that a filter a person set in the
// Inspector stays then (`ReferenceBundleReadFilterSameRowTests`). So the block remembers which bundle it last loaded and resets
// the filters that reach depth and read counts only when a different bundle loads. Those are the minimum alignment confidence,
// the two consensus quality limits, the duplicate, secondary and supplementary toggles and the read group filter. The S3BESIDE
// review (BIO SF2) found the same carry in all of them, since they ride in the one payload the viewer reads.
//
// ALIGN-CONSENSUS-SETTINGS-CARRY (3.3 lane ALIGNCARRY). Six more settings ride in that payload, and the consensus track and an
// export made from it read them, so they carried to the next bundle the same way. They are the masking switch, the gap threshold,
// the minimum depth, the masking depth, the caller mode and the IUPAC switch. They follow the same identity check, so one place
// owns the reset that a different bundle causes, and each setting goes back to the value its declaration gives it.

import Foundation

extension ReadStyleSectionViewModel {
    /// Called as a reference bundle loads into the block, before anything is read from it. A bundle other than the one the block
    /// last loaded starts every filter that changes depth or read counts, and every consensus setting, at its default. The same
    /// bundle keeps them.
    func resetConfidenceUnlessSameBundle(at bundleURL: URL) {
        let loaded = bundleURL.standardizedFileURL
        if confidenceBundleURL != loaded {
            resetDepthFilters()
            resetConsensusSettings()
        }
        confidenceBundleURL = loaded
    }

    /// Called as detached classifier evidence takes the block. The evidence has no bundle of its own, so it starts at the defaults,
    /// and the next reference bundle that loads is a different one from the last.
    func resetConfidenceForClassifierEvidence() {
        resetDepthFilters()
        resetConsensusSettings()
        confidenceBundleURL = nil
    }

    /// The Inspector filters that reach the viewer's depth and read fetch (`makeReadDisplaySettingsPayload`). `clear()` leaves them alone.
    private func resetDepthFilters() {
        minMapQ = 0
        consensusMinMapQ = 0
        consensusMinBaseQ = 0
        showDuplicates = false
        showSecondary = false
        showSupplementary = false
        selectedReadGroups = []
    }

    /// The six consensus settings that the consensus track draws from and a consensus export is made from, each back at the value
    /// it is declared with. A model nothing has touched supplies them, so the declarations stay the one place that owns a default.
    /// `clear()` leaves them alone.
    private func resetConsensusSettings() {
        let declared = ReadStyleSectionViewModel()
        consensusMaskingEnabled = declared.consensusMaskingEnabled
        consensusGapThresholdPercent = declared.consensusGapThresholdPercent
        consensusMinDepth = declared.consensusMinDepth
        consensusMaskingMinDepth = declared.consensusMaskingMinDepth
        consensusMode = declared.consensusMode
        consensusUseAmbiguity = declared.consensusUseAmbiguity
    }
}
