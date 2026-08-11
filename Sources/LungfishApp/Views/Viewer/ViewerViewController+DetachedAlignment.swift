// ViewerViewController+DetachedAlignment.swift - Full viewer entry point for classifier evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension ViewerViewController {
    /// Installs a detached BAM source in this controller's existing full viewer.
    /// The controller is deliberately retained across setting changes so navigation,
    /// zoom, and read selection remain AppKit state rather than classifier state.
    func displayDetachedAlignment(_ source: SequenceViewerView.DetachedAlignmentSource) {
        _ = view
        let width = max(800, Int(viewerView.bounds.width))
        referenceFrame = ReferenceFrame(
            chromosome: source.contig.name,
            start: 0,
            end: Double(min(source.contig.length, 10_000)),
            pixelWidth: width,
            sequenceLength: source.contig.length
        )
        viewerView.setDetachedAlignmentSource(source)
        headerView.setTrackNames([source.contig.name, "Alignments"])
        enhancedRulerView.referenceFrame = referenceFrame
        updateStatusBar()
        viewerView.needsDisplay = true
        enhancedRulerView.needsDisplay = true
    }

    /// Applies detached evidence filters without replacing the viewer/controller.
    func updateDetachedAlignmentSettings(minMapQ: Int, excludeFlags: UInt16) {
        viewerView.minMapQSetting = max(0, minMapQ)
        viewerView.excludeFlagsSetting = excludeFlags
        viewerView.invalidateDetachedAlignmentFiltersPreservingSelection()
        viewerView.needsDisplay = true
    }
}
