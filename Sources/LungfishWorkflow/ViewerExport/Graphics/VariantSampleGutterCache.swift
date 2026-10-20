// VariantSampleGutterCache.swift - The sample-name gutter width the genotype rows keep between draws
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics

/// The measured width of the sample-name gutter for one list of samples at one row height.
///
/// `VariantTrackRenderer` measured every sample label on each draw unless its static cache held
/// the same samples and row height. The cache is now a value the caller owns and passes in, so
/// the renderer keeps no state. A cache whose samples or row height differ from the draw's is
/// not used, and the renderer measures the labels again.
public struct VariantSampleGutterCache: Sendable, Equatable {
    /// The sample names the width was measured for.
    public let samples: [String]
    /// The row height the label font was sized from.
    public let rowHeight: CGFloat
    /// The gutter width, the widest label plus its padding.
    public let width: CGFloat

    public init(samples: [String], rowHeight: CGFloat, width: CGFloat) {
        self.samples = samples
        self.rowHeight = rowHeight
        self.width = width
    }

    /// The width when the cache was measured for `samples` at `rowHeight`, else nil.
    public func width(samples: [String], rowHeight: CGFloat) -> CGFloat? {
        rowHeight == self.rowHeight && samples == self.samples ? width : nil
    }
}
