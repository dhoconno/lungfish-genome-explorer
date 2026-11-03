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

    static func blastContigs(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Send the selected contigs to BLAST",
            whatHappened: "Lungfish could not read the selected contigs from the assembly output, so nothing was sent to NCBI.",
            nextStep: "Check that the assembly output is still in the project, then select the contigs and run BLAST again.",
            underlying: error
        )
    }

    static func selectedContigs(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Read the selected contigs",
            whatHappened: "Lungfish could not read all of the selected contigs from the assembly output, so the action did not run.",
            nextStep: "Check that the assembly output is still in the project, open the result again from the sidebar, then select the contigs and try again.",
            underlying: error
        )
    }
}
