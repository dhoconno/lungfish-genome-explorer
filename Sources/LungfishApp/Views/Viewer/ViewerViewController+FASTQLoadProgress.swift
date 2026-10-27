// ViewerViewController+FASTQLoadProgress.swift - The viewer while a FASTQ read set is being measured
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension ViewerViewController {

    /// Whether the progress overlay shows and no visible view lies above it.
    ///
    /// The overlay is added to the container in `loadView`, before any dashboard or result viewer exists, and every
    /// content view is added later with `addSubview`, so AppKit draws a content view that is still installed over the
    /// overlay. A load that shows its overlay while the previous content is installed therefore shows no words
    /// (Phase 3.0 lane DEMUX-STATS-BEHIND).
    var progressOverlayIsShownOnTop: Bool {
        guard !progressOverlay.isHidden,
              let siblings = progressOverlay.superview?.subviews,
              let index = siblings.firstIndex(of: progressOverlay) else { return false }
        return siblings[(index + 1)...].allSatisfy(\.isHidden)
    }

    /// Shows the progress overlay for a FASTQ read set whose statistics are being counted, with nothing of the
    /// previous content under it.
    ///
    /// `clearViewport` takes down every dashboard and result viewer, the reference viewport and the bundle chrome,
    /// and it hides the overlay first, so the overlay is shown after it. Only bringing the overlay to the front would
    /// leave the previous dashboard's buttons live and its numbers in the accessibility tree.
    public func showFASTQLoadProgress(_ message: String) {
        clearViewport(statusMessage: "")
        showProgress(message)
    }
}
