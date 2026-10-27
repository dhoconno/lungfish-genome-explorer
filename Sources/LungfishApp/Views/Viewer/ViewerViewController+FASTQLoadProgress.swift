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
}
