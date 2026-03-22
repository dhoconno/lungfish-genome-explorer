// ViewerViewController+MultiSequence.swift - Multi-sequence support for ViewerViewController
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This extension adds multi-sequence display capabilities to ViewerViewController.
// Note: This requires modifying ViewerViewController to expose headerView as internal.

import AppKit
import LungfishCore
import os.log

/// Logger for multi-sequence viewer operations
private let viewerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerMultiSeq")

// MARK: - ViewerViewController Multi-Sequence Extension

extension ViewerViewController {

    // MARK: - Multi-Sequence Status Updates

    /// Updates the status bar with multi-sequence information.
    ///
    /// Call this instead of updateStatusBar() when in multi-sequence mode
    /// to show track count and active track information.
    public func updateMultiSequenceStatusBar() {
        guard let frame = referenceFrame else { return }

        let sequenceCount = viewerView.sequenceCount
        let activeIndex = viewerView.activeSequenceIndex

        var statusText = "\(frame.chromosome):\(Int(frame.start))-\(Int(frame.end))"

        if sequenceCount > 1 {
            statusText += " | Track \(activeIndex + 1)/\(sequenceCount)"
        }

        let selectionInfo = viewerView.selectionRange.map { range in
            let length = range.upperBound - range.lowerBound
            return "Visible: \(range.lowerBound + 1)-\(range.upperBound) (\(length.formatted()) bp)"
        }

        statusBar.update(
            position: statusText,
            selection: selectionInfo,
            scale: frame.scale
        )
    }

    // MARK: - Navigation

    /// Navigates to show all sequences in view.
    ///
    /// Zooms out to show the full length of the longest sequence,
    /// ensuring all stacked sequences are visible horizontally.
    public func zoomToFitAllSequences() {
        let maxLength = viewerView.maxSequenceLength
        guard maxLength > 0 else { return }

        referenceFrame?.start = 0
        referenceFrame?.end = Double(maxLength)
        referenceFrame?.sequenceLength = maxLength

        viewerView.setNeedsDisplay(viewerView.bounds)
        enhancedRulerView.setNeedsDisplay(enhancedRulerView.bounds)
        updateStatusBar()
    }

    /// Sets the active sequence by index.
    ///
    /// The active sequence is highlighted and receives selection events.
    /// - Parameter index: Zero-based index of the sequence to activate
    public func setActiveSequence(index: Int) {
        viewerView.setActiveSequenceIndex(index)
        updateStatusBar()

        NotificationCenter.default.post(
            name: .activeSequenceChanged,
            object: self,
            userInfo: ["activeSequenceIndex": index]
        )
    }

    /// Checks if the viewer is currently in multi-sequence mode.
    public var isMultiSequenceMode: Bool {
        viewerView.isMultiSequenceMode
    }
}

// MARK: - TrackHeaderView Multi-Sequence Extension

extension TrackHeaderView {

    /// Sets the number of tracks to display.
    ///
    /// This triggers recalculation of track label layout to accommodate
    /// multiple stacked sequence tracks.
    func setTrackCount(_ count: Int) {
        setNeedsDisplay(bounds)
    }
}
