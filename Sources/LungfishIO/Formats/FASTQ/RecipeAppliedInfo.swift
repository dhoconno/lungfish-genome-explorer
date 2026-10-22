// RecipeAppliedInfo.swift - Summary of a post-import recipe run, stored in IngestionMetadata
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

// MARK: - Recipe Switch Setting

/// One switch's value in a recipe run and where the value came from (CHTC lane C2-MERGED, ruling BIO-PRESET P3).
public struct RecipeSwitchSetting: Codable, Sendable, Equatable {
    /// Where a switch's value came from.
    public enum Source: String, Codable, Sendable, Equatable {
        /// The recipe file's own default.
        case recipeDefault
        /// The preset the name resolved to.
        case preset
        /// A CLI option such as `--no-remove-duplicates`, or the sheet's checkbox.
        case option

        /// The words a run's info line and the Inspector give the source.
        public var displayName: String {
            switch self {
            case .recipeDefault: return "recipe default"
            case .preset: return "preset"
            case .option: return "option"
            }
        }
    }

    /// The switch id, such as `removeDuplicates`.
    public let id: String
    /// The switch label, such as "Remove duplicate reads".
    public let label: String
    public let value: Bool
    public let source: Source

    public init(id: String, label: String, value: Bool, source: Source) {
        self.id = id
        self.label = label
        self.value = value
        self.source = source
    }
}

// MARK: - Recipe Applied Info

/// Summary of a post-import recipe run, stored in IngestionMetadata.
public struct RecipeAppliedInfo: Codable, Sendable {
    /// Stable identifier of the recipe (e.g. "illuminaVSP2TargetEnrichment").
    public let recipeID: String
    /// Human-readable recipe display name.
    public let recipeName: String
    /// Date the recipe was applied.
    public let appliedDate: Date
    /// Ordered results for each recipe step.
    public let stepResults: [RecipeStepResult]
    /// SHA-256 of the recipe file that ran, nil for a recipe built in code or a sidecar written before 2026-10-21.
    public let recipeSHA256: String?
    /// The recipe's `formatVersion`, nil for a legacy recipe or a sidecar written before 2026-10-21.
    public let recipeFormatVersion: Int?

    public init(
        recipeID: String,
        recipeName: String,
        appliedDate: Date = Date(),
        stepResults: [RecipeStepResult],
        recipeSHA256: String? = nil,
        recipeFormatVersion: Int? = nil
    ) {
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.appliedDate = appliedDate
        self.stepResults = stepResults
        self.recipeSHA256 = recipeSHA256
        self.recipeFormatVersion = recipeFormatVersion
    }

    /// Total reads removed across all steps (input of step 0 minus output of last step).
    public var totalReadsRemoved: Int? {
        guard let first = stepResults.first?.inputReadCount,
              let last = stepResults.last?.outputReadCount else { return nil }
        return first - last
    }

    public struct ReadDeltaSummary: Equatable, Sendable {
        public let inputReads: Int
        public let outputReads: Int

        public init(inputReads: Int, outputReads: Int) {
            self.inputReads = inputReads
            self.outputReads = outputReads
        }

        public var readsRemoved: Int { inputReads - outputReads }

        public var percentRemoved: Double {
            inputReads > 0 ? Double(readsRemoved) / Double(inputReads) * 100 : 0
        }
    }

    public var deduplicationSummary: ReadDeltaSummary? {
        readDeltaSummary { step in
            step.didApplyDeduplication && !step.didApplyDeduplicationAndTrimmingInCombinedPass
        }
    }

    /// Whether any recipe step performed deduplication.
    public var didApplyDeduplication: Bool {
        stepResults.contains(where: \.didApplyDeduplication)
    }

    /// Whether deduplication was performed as part of a fused physical step.
    public var deduplicationPerformedInCombinedPass: Bool {
        stepResults.contains(where: \.didApplyDeduplicationAndTrimmingInCombinedPass)
    }

    public var humanScrubSummary: ReadDeltaSummary? {
        readDeltaSummary { step in
            let name = step.stepName.lowercased()
            let tool = step.tool.lowercased()
            return name.contains("human") || name.contains("scrub") || tool.contains("deacon")
        }
    }

    public static func readDeltaLogLine(_ label: String, _ summary: ReadDeltaSummary) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let input = formatter.string(from: NSNumber(value: summary.inputReads)) ?? "\(summary.inputReads)"
        let output = formatter.string(from: NSNumber(value: summary.outputReads)) ?? "\(summary.outputReads)"
        let pct = String(format: "%.1f", summary.percentRemoved)
        return "\(label) removed \(pct)% of reads (\(input) -> \(output))"
    }

    private func readDeltaSummary(
        matching predicate: (RecipeStepResult) -> Bool
    ) -> ReadDeltaSummary? {
        guard let step = stepResults.first(where: predicate),
              let input = step.inputReadCount,
              let output = step.outputReadCount else {
            return nil
        }
        return ReadDeltaSummary(inputReads: input, outputReads: output)
    }
}
