// TaxonomyBarWords.swift - The words the Kraken 2 action bar gives for one picked taxon
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The info line of the Kraken 2 action bar for one picked taxon.
///
/// The percent divides by the reads of the sample the row belongs to, unclassified reads included. That is the
/// count the table's `%` column divides by, so the bar and the table give one number for one row. A view that
/// merges several samples names the sample, since "all reads" would otherwise leave the reader to guess whose
/// reads. When no total is known the line gives the reads alone, because a percent of an unknown total would be
/// a number the viewer cannot stand behind.
enum TaxonomyBarWords {

    /// The line for `node`.
    ///
    /// - Parameters:
    ///   - node: The picked taxon.
    ///   - base: The read counts its percent divides by, from ``TaxonTree/readBase(for:)``.
    static func selection(for node: TaxonNode, base: TaxonTree.ReadBase?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let readStr = formatter.string(from: NSNumber(value: node.readsClade)) ?? "\(node.readsClade)"
        guard let base, base.totalReads > 0 else {
            return "\(node.name) \u{2014} \(readStr) reads"
        }
        let percent = TaxonomyPercentFormat.string(fraction: Double(node.readsClade) / Double(base.totalReads))
        let scope: String
        if let sample = base.sampleName {
            scope = " in \(sample)"
        } else if base.spansSamples {
            scope = " in the selected samples"
        } else {
            scope = ""
        }
        return "\(node.name) \u{2014} \(readStr) reads (\(percent) of all reads\(scope))"
    }
}
