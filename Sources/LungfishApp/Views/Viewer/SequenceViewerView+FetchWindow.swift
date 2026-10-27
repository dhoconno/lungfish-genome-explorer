// SequenceViewerView+FetchWindow.swift - The sequence window a reference bundle view fetches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

extension SequenceViewerView {
    /// The widest sequence window the Settings fetch cap allows, in bases.
    static var sequenceFetchCapBases: Int { AppSettings.shared.sequenceFetchCapKb * 1_000 }

    /// The bases a frame shows, as whole bases.
    static func visibleRegion(of frame: ReferenceFrame) -> GenomicRegion {
        GenomicRegion(
            chromosome: frame.chromosome,
            start: max(0, Int(frame.start)),
            end: max(Int(frame.start) + 1, Int(ceil(frame.end)))
        )
    }

    /// The bases `fetchSequenceAsync` reads for a view, or nil when no fetch can cover the view.
    ///
    /// A view at or under `capBases` gets a window centred on it, at least 100 Kb wide for panning
    /// and clamped to the chromosome, that always covers it. A view wider than the cap gets nil,
    /// since a window bounded by the cap cannot cover it and a fetch of the whole span would defeat
    /// the cap. A view that runs past the chromosome end gets nil too, since the window stops at
    /// the chromosome end. Both draw the low-zoom line.
    static func sequenceFetchWindow(
        visible: GenomicRegion,
        chromosomeLength: Int,
        capBases: Int
    ) -> GenomicRegion? {
        let visibleSpan = visible.end - visible.start
        guard visibleSpan <= capBases, visible.start >= 0, visible.end <= chromosomeLength else { return nil }
        let center = (visible.start + visible.end) / 2
        let halfFetch = min((capBases + 1) / 2, max(50_000, visibleSpan / 2 + visibleSpan))
        return GenomicRegion(
            chromosome: visible.chromosome,
            start: max(0, center - halfFetch),
            end: min(chromosomeLength, center + halfFetch)
        )
    }

    /// Whether the sequence track reads "Fetching sequence...". It does only while a fetch runs
    /// for a view that a fetch can cover, so a view wider than the cap never shows the words.
    func showsFetchingSequenceLabel(frame: ReferenceFrame) -> Bool {
        let visible = Self.visibleRegion(of: frame)
        return isFetchingBundleData
            && frame.scale < showLineThreshold
            && visible.end - visible.start <= Self.sequenceFetchCapBases
    }
}
