// MultipleSequenceAlignmentViewController+Fonts.swift - SF Mono fonts the alignment canvas keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension MultipleSequenceAlignmentViewController {
    /// Residue letters, Semibold on the consensus row and Regular on the rows. The canvas draws
    /// one per visible residue, so the fonts are looked up once for the life of the app and
    /// reused, see `DrawingFont.keptMonospaced(ofSize:weight:)`.
    static func residueFont(consensus: Bool) -> NSFont {
        consensus ? consensusResidueFont : rowResidueFont
    }

    private static let consensusResidueFont = DrawingFont.keptMonospaced(ofSize: 11, weight: .semibold)
    private static let rowResidueFont = DrawingFont.keptMonospaced(ofSize: 11, weight: .regular)
}
