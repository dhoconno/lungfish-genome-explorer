// ReferenceBundleFailureReports.swift - Failure words for the reference bundle viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts of the reference bundle viewport, each as a `FailureReport` whose error text goes only to
/// the details area (ALERT-PRESENTER, Phase 3.1).
enum ReferenceBundleFailureReports {
    /// Copying the sequences of the selected rows reads each one from the bundle and puts them on the pasteboard
    /// only after the last one, so a failure leaves the pasteboard as it was.
    static func copySequences(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Copy the reference sequences",
            whatHappened: "Lungfish could not read the sequences from the bundle, so nothing was copied.",
            nextStep: "Check that the bundle is still in the project and can be read, then copy the sequences again.",
            underlying: error
        )
    }
}
