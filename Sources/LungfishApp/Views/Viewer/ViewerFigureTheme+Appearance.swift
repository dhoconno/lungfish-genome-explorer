// ViewerFigureTheme+Appearance.swift - The figure theme and frame of the live viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

extension ViewerFigureTheme {
    /// The figure theme for an AppKit appearance: dark when the best match of `[.aqua, .darkAqua]`
    /// is `.darkAqua`, else light (UX-Q-G2 item 6). The live viewer resolves it from its
    /// `effectiveAppearance` on each draw, and the graphic export passes the same choice.
    public static func resolved(for appearance: NSAppearance) -> ViewerFigureTheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension ReferenceFrame {
    /// The live frame as the `Sendable` value the figure renderers take.
    public var figureFrame: ViewerFigureFrame {
        ViewerFigureFrame(
            chromosome: chromosome, start: start, end: end, pixelWidth: pixelWidth,
            sequenceLength: sequenceLength, leadingInset: leadingInset, trailingInset: trailingInset
        )
    }
}
