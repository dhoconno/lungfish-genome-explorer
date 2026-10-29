// GenotypeFailureReports.swift - Failure words for the genotype result view's exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the genotype result view shows for its exports, each as a `FailureReport` whose error text
/// goes only to the details area (ALERT-PRESENTER, Phase 3.1). A failure of the export command runs behind an
/// Operations row, so its next step points to that row's log. Any other error stopped before a row ran.
enum GenotypeFailureReports {
    static func exportGenotypeView(_ error: any Error) -> FailureReport {
        if error is CLIViewerExportRunner.Failure {
            return FailureReport(
                failedStep: "Export the genotype view",
                whatHappened: "The export command stopped before it wrote the file.",
                nextStep: "Open the Operations panel to read the log of this export, then export the view again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Export the genotype view",
            whatHappened: "The genotype view was not written to the Excel file.",
            nextStep: "Check that the folder you chose can be written to and has free space, then export the view again.",
            underlying: error
        )
    }

    static func exportManualHaplotypeDefinitions(_ error: any Error) -> FailureReport {
        if error is CLIViewerExportRunner.Failure {
            return FailureReport(
                failedStep: "Export the manual haplotype definitions",
                whatHappened: "The export command stopped before it wrote the file.",
                nextStep: "Open the Operations panel to read the log of this export, then export the definitions again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Export the manual haplotype definitions",
            whatHappened: "Lungfish could not prepare the definitions for export, so no file was written.",
            nextStep: "Check that the folder you chose can be written to and has free space, then export the definitions again.",
            underlying: error
        )
    }
}
