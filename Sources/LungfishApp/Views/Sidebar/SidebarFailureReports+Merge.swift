// SidebarFailureReports+Merge.swift - Failure words for "Merge into New Bundle"
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishOperations

extension SidebarFailureReports {
    /// "Merge into New Bundle" failed after the person named the bundle (ALERT-C4). A FASTQ merge throws
    /// `FASTQBundleMergeServiceError`, which is internal to LungfishOperations, so the words cannot match its
    /// sentences by type and the sentence stays in the details. A reference merge runs under the row
    /// "Merge Reference Bundles", which `ReferenceBundleMergeRoute.merge` fails and logs before it rethrows, and a
    /// refused row (another operation holds a bundle) is the same row in the panel.
    static func mergeIntoNewBundle(kind: BundleMergeSelectionKind, _ error: any Error) -> FailureReport {
        switch kind {
        case .fastq:
            // Reads built from sequence counts are refused before any bundle is made (FLUIDIGM-CHILDREN F6).
            if let bundleName = FASTQBundleMergeService.placeholderScoreRefusal(in: error) {
                return FailureReport(
                    failedStep: "Merge the selected FASTQ bundles into a new bundle",
                    whatHappened: "\(bundleName) holds reads built from sequence counts. Their quality scores were written, not measured, and a merged dataset would show them as measured, so Lungfish does not merge it.",
                    nextStep: "Leave \(bundleName) out and merge the other bundles, or work with each bundle on its own.",
                    underlying: error
                )
            }
            return FailureReport(
                failedStep: "Merge the selected FASTQ bundles into a new bundle",
                whatHappened: "The selected FASTQ bundles were not merged, so no new bundle was added to the project.",
                nextStep: "Check that all of the bundles are single-end or all are paired-end, that the new name is not used yet in the folder and that the project folder has free space, then merge them again.",
                underlying: error
            )
        case .reference:
            return FailureReport(
                failedStep: "Merge the selected reference bundles into a new bundle",
                whatHappened: "The selected reference bundles were not merged, so no new bundle was added to the project.",
                nextStep: "Open the Operations panel to read the log of this merge. Check that each bundle can be read, that no two share a sequence name and that the project folder has free space, then merge them again.",
                underlying: error
            )
        }
    }
}
