// SidebarFailureReports+Merge.swift - Failure words for "Merge into New Bundle"
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension SidebarFailureReports {
    /// "Merge into New Bundle" failed after the person named the bundle (ALERT-C4). A FASTQ merge throws
    /// `FASTQBundleMergeServiceError`, which is internal to LungfishOperations, so the words cannot match its
    /// sentences by type and the sentence stays in the details. A reference merge runs under the row
    /// "Merge Reference Bundles", which `ReferenceBundleMergeRoute.merge` fails and logs before it rethrows, and a
    /// refused row (another operation holds a bundle) is the same row in the panel.
    static func mergeIntoNewBundle(kind: BundleMergeSelectionKind, _ error: any Error) -> FailureReport {
        switch kind {
        case .fastq:
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
