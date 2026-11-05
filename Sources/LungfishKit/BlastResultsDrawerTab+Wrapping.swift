// BlastResultsDrawerTab+Wrapping.swift - The pane's summary and failure words wrap, and a running search names its sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension BlastResultsDrawerTab {
    /// Lets the summary and the failure words wrap at the width the pane has, so no word is cut (lane BLASTWORDS, W-7 and W-25).
    ///
    /// The summary bar is 36 points tall while the summary fits on one line and grows with the summary when it needs more.
    /// The failure words keep to 24 points from each edge, so a pane narrower than their 400 points wraps them again.
    func installWrappingLabels() {
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let preferredHeight = summaryBar.heightAnchor.constraint(equalToConstant: 36)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            preferredHeight,
            summaryLabel.topAnchor.constraint(greaterThanOrEqualTo: summaryBar.topAnchor, constant: 8),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: summaryBar.bottomAnchor, constant: -8),
            emptyStateDetailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyStateContainer.leadingAnchor, constant: 24),
            emptyStateDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyStateContainer.trailingAnchor, constant: -24),
        ])
    }

    /// The line under the progress bar. It names the sample the search is about when it is known, then the request ID when
    /// NCBI has given one, as `Sample SRR1. Request ID: R1` (W-21).
    static func loadingDetail(requestId: String?, subject: String?) -> String {
        [subject, requestId.map { "Request ID: \($0)" }].compactMap { $0 }.joined(separator: ". ")
    }
}
