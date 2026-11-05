// TaxonomySunburstView+TooltipBase.swift - The read counts the sunburst tooltip divides by
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO

extension TaxonomySunburstView {

    /// The read counts the tooltip of `node` divides by.
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
        tree.readBase(for: node)
    }
}
