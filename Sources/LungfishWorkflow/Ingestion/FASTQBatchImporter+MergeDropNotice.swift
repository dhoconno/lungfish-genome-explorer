// FASTQBatchImporter+MergeDropNotice.swift - The notice an import logs when its merge dropped the pairs that did not merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQBatchImporter {
    /// One notice for each merge step that dropped pairs, for example `Illumina Amplicon Merge kept 20,000 merged reads
    /// and dropped 60,000 pairs that did not merge.` (row AMPLICON-MERGE-DROP-WORDS). The Operations row logs it as a
    /// warning line, since a person who chose the recipe may not expect that pairs which do not overlap are not stored.
    ///
    /// Both counts are the ones the tool's report gave. A step that dropped no pair, one whose report gave no unmerged
    /// pairs and one that holds no merged read count give no notice, so no sentence names a figure that the report did
    /// not give or one worked out from the step's other counts.
    static func mergeDropNotices(sample: String, recipeApplied: RecipeAppliedInfo) -> [ImportLogEvent] {
        recipeApplied.stepResults.compactMap { step -> ImportLogEvent? in
            guard step.didRun, let dropped = step.droppedUnmergedPairs, dropped > 0,
                  let merged = step.outputReadCount else { return nil }
            let kept = "\(recipeApplied.recipeName) kept \(mergeDropCount(merged)) merged \(merged == 1 ? "read" : "reads")"
            let lost = "dropped \(mergeDropCount(dropped)) \(dropped == 1 ? "pair" : "pairs") that did not merge."
            return .notice(sample: sample, message: "\(kept) and \(lost)")
        }
    }

    /// A count with its thousands grouped by commas, as the words around it are English.
    private static func mergeDropCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
