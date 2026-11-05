// TaxonomySunburstView+TooltipBase.swift - The read counts the sunburst tooltip divides by
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension TaxonomySunburstView {

    /// The read counts the tooltip of `node` divides by.
    ///
    /// The wedge that sums small taxa is never linked into the tree, so asking the tree about it finds no sample and
    /// returns the counts of every selected sample together. Its segment records the real node whose small children
    /// it sums, and that node's sample is the wedge's sample. Any other node asks the tree directly.
    ///
    /// - Parameters:
    ///   - node: The hovered node.
    ///   - segments: The segments the view drew.
    ///   - tree: The tree the view shows.
    static func tooltipReadBase(
        for node: TaxonNode,
        segments: [SunburstSegment],
        tree: TaxonTree
    ) -> TaxonTree.ReadBase {
        tree.readBase(for: segments.first { $0.node === node }?.owner ?? node)
    }
}
