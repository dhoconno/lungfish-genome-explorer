// ReadTrackRenderer+Fonts.swift - SF Mono font the read track renderer keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreText

extension ReadTrackRenderer {
    /// Base-mode insertion labels, one per insertion, in SF Mono semibold at 7 points, the face
    /// `DrawingFont.keptMonospaced(ofSize: 7, weight: .semibold)` gave the live view.
    static func insertionLabelFont() -> CTFont {
        ViewerFigureTrackText.font(.monospacedSemibold, size: 7)
    }
}
