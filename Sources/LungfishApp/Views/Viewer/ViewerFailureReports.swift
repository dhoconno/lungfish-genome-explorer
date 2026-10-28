// ViewerFailureReports.swift - Failure words for the viewer's tables, sequences and alignments
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the viewer's drawer, sequence view and alignment view
/// show, each as a `FailureReport` whose error text goes only to the details
/// area (ALERT-PRESENTER, Phase 3.1).
enum ViewerFailureReports {
    static func exportTable(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Export the table",
            whatHappened: "The table rows were not written to a file.",
            nextStep: "Check that the folder you save to can be written to and has free space, then export the table again.",
            underlying: error
        )
    }

    static func deleteSampleMetadataColumn(_ columnName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Delete the \(columnName) column",
            whatHappened: "The column was not removed from the sample metadata.",
            nextStep: "Check that the bundle folder can be written to, then delete the column again.",
            underlying: error
        )
    }

    static func prepareSelectedSequence(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Prepare the selected sequence",
            whatHappened: "Lungfish could not read the selected bases, so the sequence operation did not open.",
            nextStep: "Select the sequence or region again, then choose the operation again. If it fails again, close and reopen the bundle.",
            underlying: error
        )
    }

    static func applyAlignmentAnnotations(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Apply the annotations to the selected rows",
            whatHappened: "The annotations were not copied to the selected rows.",
            nextStep: "Check that the alignment bundle can be written to, then apply the annotations again.",
            underlying: error
        )
    }

    static func addAlignmentAnnotation(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Add the annotation",
            whatHappened: "The new annotation was not saved in the alignment bundle.",
            nextStep: "Check that the alignment bundle can be written to, then add the annotation again.",
            underlying: error
        )
    }
}
