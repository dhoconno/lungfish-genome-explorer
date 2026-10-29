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

    // MARK: Edits of the annotations a bundle keeps

    // The store writes a bundle's annotations into its folder, and a failed edit leaves the saved file as it was.
    // A newer file from another window or process is the one refusal the store words itself, so its fact stays
    // in the body by its typed case. The editor's own sentence about a missing store stays by its type.

    static func openAnnotationsForSampleStatus(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Change the sample status",
            whatHappened: "Lungfish could not open the annotations of the bundle, so the sample status was not changed.",
            nextStep: "Check that the bundle folder is still there and can be read, then change the sample status again.",
            underlying: error
        )
    }

    static func changeSampleStatus(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Change the sample status",
                       whatHappened: "The new sample status was not saved to the bundle.", again: "change the sample status")
    }

    static func saveSmartCohort(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Save the smart cohort",
                       whatHappened: "The smart cohort was not saved to the bundle.", again: "save the smart cohort")
    }

    static func deleteSmartCohort(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Delete the smart cohort",
                       whatHappened: "The smart cohort was not deleted from the bundle.", again: "delete the smart cohort")
    }

    static func restoreBuiltInCohorts(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Restore the built-in cohorts",
                       whatHappened: "The built-in cohorts were not restored in the bundle.", again: "restore the built-in cohorts")
    }

    static func saveAnnotationStyle(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Save the annotation style",
                       whatHappened: "The annotation style was not saved to the bundle.", again: "save the annotation style")
    }

    static func saveMatrixAnnotation(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Save the matrix annotation",
                       whatHappened: "The matrix annotation was not saved to the bundle.", again: "save the annotation")
    }

    static func saveManualHaplotypeAssignments(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Save the manual haplotype assignments",
                       whatHappened: "The manual haplotype assignments were not saved to the bundle.", again: "save the assignments")
    }

    static func removeManualHaplotype(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Remove the manual haplotype",
                       whatHappened: "The manual haplotype was not removed from the bundle.", again: "remove the haplotype")
    }

    static func confirmCall(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Confirm the call",
                       whatHappened: "The confirmation of the call was not saved to the bundle.", again: "confirm the call")
    }

    static func saveHaplotypeChange(_ error: any Error) -> FailureReport {
        annotationEdit(error, step: "Save the haplotype change",
                       whatHappened: "The haplotype change was not saved to the bundle.", again: "save the haplotype change")
    }

    private static func annotationEdit(_ error: any Error, step: String, whatHappened: String, again: String) -> FailureReport {
        if let refusal = error as? GenotypeAnnotationStorePersistenceError, case .staleRevision = refusal {
            return FailureReport(
                failedStep: step,
                whatHappened: "The genotype annotations changed in another process, so this edit was not applied.",
                nextStep: "Reload the bundle, then \(again) again.",
                underlying: error
            )
        }
        if error is GenotypeResultViewController.ManualHaplotypeEditorError {
            return FailureReport(
                failedStep: step,
                whatHappened: error.localizedDescription,
                nextStep: "Reopen the bundle, then \(again) again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: step,
            whatHappened: whatHappened,
            nextStep: "Check that the bundle folder can be written to and has free space, then \(again) again.",
            underlying: error
        )
    }
}
