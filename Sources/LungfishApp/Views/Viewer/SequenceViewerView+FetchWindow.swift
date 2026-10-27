// SequenceViewerView+FetchWindow.swift - The sequence window a reference bundle view fetches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

extension SequenceViewerView {
    /// The bases `fetchSequenceAsync` reads for a view.
    ///
    /// The window is centred on the view, at least 100 Kb wide for panning, at most `capBases`
    /// wide, and clamped to the chromosome.
    static func sequenceFetchWindow(
        visible: GenomicRegion,
        chromosomeLength: Int,
        capBases: Int
    ) -> GenomicRegion {
        let center = (visible.start + visible.end) / 2
        let visibleSpan = visible.end - visible.start
        let halfFetch = min(capBases / 2, max(50_000, visibleSpan / 2 + visibleSpan))
        return GenomicRegion(
            chromosome: visible.chromosome,
            start: max(0, center - halfFetch),
            end: min(chromosomeLength, center + halfFetch)
        )
    }

    /// Whether the sequence track reads "Fetching sequence...".
    func showsFetchingSequenceLabel(frame: ReferenceFrame) -> Bool {
        isFetchingBundleData && frame.scale < showLineThreshold
    }
}
