// PinchZoomFactor.swift - Shared pinch-to-zoom factor mapping
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Maps a trackpad magnification delta to a clamped zoom multiplier.
///
/// Extracted from `SequenceViewerView.pinchZoomFactor` so embedded viewers
/// (e.g. the mini-BAM pileup) can share the exact same pinch-zoom semantics
/// without depending on the full sequence viewer.
public enum PinchZoom {

    /// Converts a magnification delta into a zoom factor clamped to `0.125...8.0`.
    public static func factor(magnification: CGFloat) -> Double {
        let proposed = 1.0 + Double(magnification)
        return min(8.0, max(0.125, proposed))
    }
}
