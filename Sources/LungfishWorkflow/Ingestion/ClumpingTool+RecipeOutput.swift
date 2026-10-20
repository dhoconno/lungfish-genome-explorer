// ClumpingTool+RecipeOutput.swift - storage tools that cannot keep a recipe's output together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension Recipe {
    /// Whether this recipe, run on read pairs, writes merged reads and read
    /// pairs into one file. A merge step that keeps the unmerged mates leaves
    /// the merged layout, which the engine writes as one mixed file.
    public var outputMixesMergedReadsAndPairs: Bool {
        guard let plan = try? RecipeEngine().plan(recipe: self, inputFormat: .pairedR1R2) else {
            return false
        }
        return plan.contains { step in
            if case .formatConversion(from: .merged, to: .mixed) = step { return true }
            return false
        }
    }
}

extension ProcessingRecipe {
    /// Whether this legacy recipe merges pairs. Its merge step always writes
    /// the unmerged mates beside the merged reads.
    public var outputMixesMergedReadsAndPairs: Bool {
        steps.contains { $0.kind == .pairedEndMerge }
    }
}

extension ClumpingTool {
    /// Why this storage tool cannot store what the recipe named `recipeName`
    /// writes, or nil when it can. Trim Galore keeps mates together by
    /// splitting a file of pairs into R1 and R2, which a file that also holds
    /// merged reads cannot be, so it fails only after the whole recipe has run.
    public func refusalToStore(recipeNamed recipeName: String, outputMixesMergedReadsAndPairs: Bool) -> String? {
        guard self == .trimGalore, outputMixesMergedReadsAndPairs else { return nil }
        return "Trim Galore cannot store the output of \(recipeName). The recipe merges overlapping pairs, "
            + "so its output mixes merged reads with read pairs, and Trim Galore keeps mates together only "
            + "in a file of pairs. Choose BBTools clumpify, or skip storage optimization."
    }
}
