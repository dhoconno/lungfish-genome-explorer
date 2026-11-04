// BlastResultsDrawerTab+Summary.swift - The summary bar text of the BLAST results pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

extension BlastResultsDrawerTab {
    /// The summary bar text for a taxon verification.
    ///
    /// Reads that NCBI returned no usable result for are counted on their own, so
    /// they are not mistaken for reads that found no hit. When read pairs were
    /// sent the counts are fragments, and the end says how many reads were sent.
    /// `subject` names the sample the verdict is about, right after the taxon, since the label cuts its tail and the
    /// counts must not be the part that goes (lane ROWPANE). Nil names no sample.
    public static func verificationSummary(for result: BlastVerificationResult, subject: String? = nil) -> String {
        var text = "BLAST for \(result.taxonName)\(subjectWords(subject)): \(result.supportingCount) supporting, \(result.contradictingCount) contradicting"
        if result.errorCount > 0 {
            text += ", \(result.errorCount) with no BLAST result"
        }
        let (rows, sent) = (result.totalReads, result.judgedSequenceCount)
        return text + (sent > rows ? " (\(rows) \(rows == 1 ? "fragment" : "fragments"), \(sent) reads)" : " (\(rows) \(rows == 1 ? "read" : "reads"))")
    }

    /// The words that name the sample a verdict is about, or nothing when no sample is known.
    static func subjectWords(_ sample: String?) -> String {
        guard let sample, !sample.isEmpty else { return "" }
        return " (sample \(sample))"
    }
}
