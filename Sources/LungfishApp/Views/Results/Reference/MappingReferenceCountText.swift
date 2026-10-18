// MappingReferenceCountText.swift - The summary-bar clause for reference sequences a mapping left out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

/// The clause the mapping summary bar shows when a result left out reference
/// sequences with no alignments (UX ruling Q-B2). An absent count means
/// unknown, so a schema-1 result shows nothing.
enum MappingReferenceCountText {
    struct Text: Equatable {
        let label: String
        let help: String
    }

    /// The label and help for these counts, or `nil` when the counts are
    /// unknown, nothing was left out, the reference holds one sequence, or
    /// the stored rows contradict the counts.
    static func make(referenceCount: Int?, unalignedReferenceCount: Int?, storedRowCount: Int) -> Text? {
        guard let total = referenceCount,
              let unaligned = unalignedReferenceCount,
              total >= 2,
              unaligned > 0,
              unaligned <= total,
              storedRowCount + unaligned == total
        else { return nil }
        let aligned = total - unaligned
        let label = "\(aligned.formatted()) of \(total.formatted()) reference sequences \(aligned == 1 ? "has" : "have") alignments"
        let help = unaligned == 1
            ? "1 reference sequence has no alignments in this mapping and is not listed."
            : "\(unaligned.formatted()) reference sequences have no alignments in this mapping and are not listed."
        return Text(label: label, help: help)
    }

    /// A secondary, regular-weight label that truncates before the summary
    /// text does. VoiceOver reads its value, so it sets no accessibility label.
    @MainActor
    static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        label.setAccessibilityIdentifier("reference-bundle-reference-count-label")
        label.setAccessibilityRole(.staticText)
        return label
    }

    /// Shows the clause for `result`, or hides the label when there is none.
    @MainActor
    static func apply(to label: NSTextField, result: MappingResult?) {
        let text = result.flatMap {
            make(
                referenceCount: $0.referenceCount,
                unalignedReferenceCount: $0.unalignedReferenceCount,
                storedRowCount: $0.contigs.count
            )
        }
        label.stringValue = text?.label ?? ""
        label.toolTip = text?.help
        label.setAccessibilityHelp(text?.help)
        label.isHidden = text == nil
    }
}
