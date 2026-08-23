// ViewerViewController+DetachedAlignment.swift - Full viewer entry point for classifier evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension ViewerViewController {
    /// Installs a detached BAM source in this controller's existing full viewer.
    /// The controller is deliberately retained across setting changes so navigation,
    /// zoom, and read selection remain AppKit state rather than classifier state.
    @discardableResult
    func displayDetachedAlignment(_ source: SequenceViewerView.DetachedAlignmentSource) -> Bool {
        _ = view
        let width = max(800, Int(viewerView.bounds.width))
        // A freshly loaded contig opens at full width so every mapped read is in
        // view; the user zooms in from there rather than discovering reads that
        // sit beyond an arbitrary 10 kb window.
        referenceFrame = Self.initialDetachedReferenceFrame(
            contigName: source.contig.name,
            contigLength: source.contig.length,
            pixelWidth: width
        )
        guard viewerView.setDetachedAlignmentSource(source) else { return false }
        headerView.setTrackNames([source.contig.name, "Alignments"])
        enhancedRulerView.referenceFrame = referenceFrame
        updateStatusBar()
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
        return true
    }

    /// The frame a detached contig is first shown in: the whole contig.
    static func initialDetachedReferenceFrame(
        contigName: String,
        contigLength: Int,
        pixelWidth: Int
    ) -> ReferenceFrame {
        ReferenceFrame(
            chromosome: contigName,
            start: 0,
            end: Double(max(1, contigLength)),
            pixelWidth: pixelWidth,
            sequenceLength: contigLength
        )
    }

    /// Opening window for a reference bundle: the whole chromosome when reads
    /// are mapped to it (every BAM viewer opens at full width), otherwise the
    /// first 10 kb.
    static func initialBundleWindowLength(chromosomeLength: Int, hasAlignmentTracks: Bool) -> Int {
        hasAlignmentTracks ? max(1, chromosomeLength) : min(chromosomeLength, 10_000)
    }

    /// Applies detached evidence filters without replacing the viewer/controller.
    func updateDetachedAlignmentSettings(minMapQ: Int, excludeFlags: UInt16) {
        viewerView.minMapQSetting = max(0, minMapQ)
        viewerView.excludeFlagsSetting = excludeFlags
        viewerView.invalidateDetachedAlignmentFiltersPreservingSelection()
        viewerView.needsDisplay = true
    }
}
