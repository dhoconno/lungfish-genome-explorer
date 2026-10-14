// ClassificationCompletionDetail.swift - The text a Kraken2 or EsViritu row ends on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The completion and failure details of the Kraken2 and EsViritu runs, in the words the
/// Operations panel has always shown.
///
/// The legacy app route, the executor and the CLI's text summary build their detail line here,
/// so one outcome reads the same on every route. The strings are the ones the app's launch
/// closures built inline before they moved, and `ClassificationCompletionDetailTests` pins each
/// one. The detail of a single Kraken2 sample, `<c> of <t> reads classified` with its degraded
/// Bracken clause, comes from ``ClassificationBatchOutcomePolicy/singleResultMetadata(for:)``.
public enum ClassificationCompletionDetail {
    /// The detail of a finished Kraken2 batch. It names how many samples returned valid
    /// classifications, and it ends with the evaluation's warnings after a semicolon when the
    /// batch needs a warning completion.
    public static func kraken2Batch(
        successCount: Int,
        sampleCount: Int,
        evaluation: ClassificationBatchOutcomeEvaluation
    ) -> String {
        let base = "\(successCount) of \(sampleCount) samples returned valid Kraken2 classifications"
        guard evaluation.requiresWarningCompletion else { return base }
        return "\(base); \(evaluation.warningMessage)"
    }

    /// The detail of a finished EsViritu sample. A run with no detection reads
    /// `No viral hits detected`, and each count noun follows its count, as in
    /// `1 virus detected in 1 family` (Phase 2.10 W4).
    public static func esVirituDetection(virusCount: Int, familyCount: Int) -> String {
        virusCount == 0
            ? "No viral hits detected"
            : esVirituCounts(virusCount: virusCount, familyCount: familyCount)
    }

    /// The counts of an EsViritu sample in words, `3 viruses detected in 2 families`, with each noun in
    /// the number its count asks for. The sample's source bundle entry reads the same words.
    public static func esVirituCounts(virusCount: Int, familyCount: Int) -> String {
        "\(counted(virusCount, "virus", "viruses")) detected in \(counted(familyCount, "family", "families"))"
    }

    /// A count with its noun in the number the count asks for, `1 family` and `2 families`.
    public static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// The detail of a finished EsViritu batch. A batch with failed samples names both counts.
    public static func esVirituBatch(successCount: Int, failureCount: Int, sampleCount: Int) -> String {
        failureCount == 0
            ? "\(successCount) of \(sampleCount) samples completed"
            : "\(successCount) completed, \(failureCount) failed"
    }

    /// The detail of a batch in which every sample failed. It is the first sample's error, or
    /// `All samples failed` when no error text was kept.
    public static func allSamplesFailed(firstError: String?) -> String {
        firstError ?? "All samples failed"
    }

    /// The detail of a batch the user cancelled.
    public static let batchCancelled = "Batch cancelled"
}
