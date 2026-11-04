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
        let counted = countedRows(of: result)
        return text + " (\(counted.rows)\(counted.sent.map { ", " + $0 } ?? ""))"
    }

    /// Sets the one-line summary, its tooltip and its help for a taxon verification. How the row was judged is not part of
    /// it, since the label cuts its tail and that caveat must not go (BLASTCOLLECT-UX-2). It has ``judgedAtLabel``.
    func applyVerificationSummary(result: BlastVerificationResult, subject: String?, recordURL: URL?) {
        let badgeWords = BlastTieWords.notSpecificSummary(for: result)
        summaryLabel.stringValue = Self.verificationSummary(for: result, subject: subject)
            + (badgeWords.map { ". " + $0 } ?? "") + Self.collectedWords(recordURL: recordURL)
        [summaryLabel, confidenceLabel].forEach { $0.toolTip = badgeWords; $0.setAccessibilityHelp(badgeWords) }
    }

    /// What a verdict's counts are of, and what went out when that differs, one reading for the pane and the Operations row.
    nonisolated static func countedRows(of result: BlastVerificationResult) -> (rows: String, sent: String?) {
        let (rows, sent) = (result.totalReads, result.judgedSequenceCount)
        guard sent > rows else { return ("\(rows) \(rows == 1 ? "read" : "reads")", nil) }
        return ("\(rows) \(rows == 1 ? "fragment" : "fragments")", "\(sent) reads")
    }

    /// The Operations row's reading of ``countedRows(of:)``, as `1 fragment (2 reads)`.
    nonisolated public static func countedRowWords(of result: BlastVerificationResult) -> String {
        let counted = countedRows(of: result)
        return counted.rows + (counted.sent.map { " (\($0))" } ?? "")
    }

    /// What a row whose words are its own adds for a search that came back (UX-BLAST-WORDS Q1 row 7), or nothing for a record
    /// with no search file beside it.
    nonisolated public static func collectedRowWords(recordURL: URL?) -> String {
        guard let folder = recordURL?.deletingLastPathComponent(), let file = try? BlastSearchStore(folder: folder).load(),
              let line = BlastSearchWords.collected(in: file) else { return "" }
        return ". " + line
    }

    /// What the pane adds to the summary of a search that came back (UX-BLAST-WORDS Q7), or nothing for a record with no
    /// search file beside it, which is every record from before searches had one.
    nonisolated public static func collectedWords(recordURL: URL?) -> String {
        guard let folder = recordURL?.deletingLastPathComponent(), let file = try? BlastSearchStore(folder: folder).load(),
              let line = BlastSearchWords.collectedOnThePane(in: file) else { return "" }
        return ". " + line
    }

    /// The words that name the sample a verdict is about, or nothing when no sample is known.
    static func subjectWords(_ sample: String?) -> String {
        guard let sample, !sample.isEmpty else { return "" }
        return " (sample \(sample))"
    }
}

/// The line under the summary bar that says how a verdict was judged (BLAST-ESVIRITU-FIRST-WORD). It has a row of its
/// own because the one-line summary label cuts its tail, and this caveat is the part a person must not miss. With no
/// words the row has no height, since a hidden view still holds its space in Auto Layout.
@MainActor
public final class BlastJudgedAtLabel: NSTextField {
    private var collapsedHeight: NSLayoutConstraint?

    /// A label hung from the bottom of `bar` inside `container`, collapsed until it has words.
    public static func installed(below bar: NSView, in container: NSView) -> BlastJudgedAtLabel {
        let label = BlastJudgedAtLabel(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.setAccessibilityLabel("How this row was judged")
        label.isHidden = true
        container.addSubview(label)
        let collapsed = label.heightAnchor.constraint(equalToConstant: 0)
        label.collapsedHeight = collapsed
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bar.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            collapsed,
        ])
        return label
    }

    /// Shows `words`, or gives the row no height when there are none.
    public func show(_ words: String?) {
        stringValue = words ?? ""
        collapsedHeight?.isActive = (words == nil)
        isHidden = (words == nil)
    }
}
