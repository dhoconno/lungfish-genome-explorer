// FlagstatSummary.swift - A parsed samtools flagstat report
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

/// A parsed `samtools flagstat` report.
///
/// Values are keyed by flagstat's own category names so that a samtools release
/// adding a category is carried through rather than dropped, while the counts
/// the app actually reads are exposed as named properties.
public struct FlagstatSummary: Sendable, Equatable {

    /// QC-passed and QC-failed counts for a single flagstat category.
    public struct Counts: Sendable, Equatable {
        public let qcPass: Int64
        public let qcFail: Int64

        public init(qcPass: Int64, qcFail: Int64) {
            self.qcPass = qcPass
            self.qcFail = qcFail
        }
    }

    /// Every category flagstat reported, keyed by category name (`total`,
    /// `mapped`, `duplicates`, ...).
    public let categories: [String: Counts]

    /// The same category names in the order samtools reported them: source
    /// line order for the text form, key order for the `-O json` form.
    ///
    /// A dictionary has no order, so anything that renders these counts (the
    /// inspector's flag-stat table, the `flag_stats` rows) would otherwise
    /// reshuffle between runs on byte-identical input. samtools orders its
    /// output meaningfully (the total first, then the breakdown), so that
    /// order is preserved rather than replaced with an alphabetical sort.
    ///
    /// Always exactly the keys of ``categories``, with no duplicates.
    public let orderedCategories: [String]

    /// Creates a summary, preserving the caller's category order.
    ///
    /// - Parameter ordered: Category/count pairs in the order samtools reported
    ///   them. A repeated category keeps its first position and takes the last
    ///   value, matching the dictionary-assignment behaviour of the parsers.
    public init(ordered: [(String, Counts)]) {
        var categories: [String: Counts] = [:]
        var order: [String] = []
        for (name, counts) in ordered {
            if categories.updateValue(counts, forKey: name) == nil {
                order.append(name)
            }
        }
        self.categories = categories
        self.orderedCategories = order
    }

    /// Creates a summary from an unordered dictionary.
    ///
    /// Category order falls back to a stable alphabetical sort, since a
    /// dictionary carries no source order to preserve. Prefer ``init(ordered:)``
    /// from a parser, which knows the order samtools used.
    public init(categories: [String: Counts]) {
        self.categories = categories
        self.orderedCategories = categories.keys.sorted()
    }

    /// QC-passed count for a category, or `nil` when flagstat did not report it.
    public func count(_ category: String) -> Int64? {
        categories[category]?.qcPass
    }

    /// QC-passed reads in total.
    public var totalReads: Int64 { count("total") ?? 0 }

    /// QC-passed mapped reads.
    public var mappedReads: Int64 { count("mapped") ?? 0 }

    /// QC-passed duplicate reads.
    public var duplicateReads: Int64 { count("duplicates") ?? 0 }

    /// QC-passed properly paired reads.
    public var properlyPaired: Int64 { count("properly paired") ?? 0 }
}
