// AssemblyFailureReports.swift - Failure words for the assembly result view
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the assembly result view shows, each as a `FailureReport` whose error text goes only to
/// the details area (ALERT-PRESENTER, Phase 3.1).
enum AssemblyFailureReports {
    static func copyContigFASTA(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Copy the contig FASTA",
            whatHappened: "Lungfish could not read the selected contigs from the assembly output, so nothing was copied.",
            nextStep: "Check that the assembly output is still in the project, then select the contigs and copy them again.",
            underlying: error
        )
    }
}
