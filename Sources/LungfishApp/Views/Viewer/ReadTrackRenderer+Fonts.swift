// ReadTrackRenderer+Fonts.swift - SF Mono font the read track renderer keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension ReadTrackRenderer {
    /// Base-mode insertion labels, one per insertion. The renderer has no instances, so it
    /// looks the font up once for the life of the app and reuses it on every draw, see
    /// `DrawingFont.keptMonospaced(ofSize:weight:)`.
    static let insertionLabelFont = DrawingFont.keptMonospaced(ofSize: 7, weight: .semibold)
}
