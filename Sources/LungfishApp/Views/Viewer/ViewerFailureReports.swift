// ViewerFailureReports.swift - Failure words for the viewer's tables, sequences and alignments
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit

/// The failure alerts the viewer's drawer, sequence view and alignment view
/// show, each as a `FailureReport` whose error text goes only to the details
/// area (ALERT-PRESENTER, Phase 3.1).
enum ViewerFailureReports {
    static func exportTable(_ error: any Error) -> FailureReport {
        // Two typed errors carry words the app wrote. The row refusal stays in the body, and the export command's
        // message goes to the details with a pointer to its Operations row (ALERT review SF1b).
        if error is AnnotationTableExportRowNotStored {
            return FailureReport(
                failedStep: "Export the table",
                whatHappened: error.localizedDescription,
                nextStep: "Leave that row out of the selection, then export the table again.",
                underlying: error
            )
        }
        if error is AnnotationTableExportLeafFailure {
            return FailureReport(
                failedStep: "Export the table",
                whatHappened: "The export command stopped before it wrote the file.",
                nextStep: "Open the Operations panel to read the log of this export, then export the table again.",
                underlying: error
            )
        }
        return FailureReport(
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
        // An empty range is a refusal the app words, so its next step says what to select (ALERT review SF1d).
        // The other callee error, no sequence, and the file errors keep the general words.
        if let inputError = error as? SequenceViewerView.FASTAOperationInputError,
           case .emptyRange = inputError {
            return FailureReport(
                failedStep: "Prepare the selected sequence",
                whatHappened: "The selected range holds no bases, so the sequence operation did not open.",
                nextStep: "Select a range that holds at least one base, then choose the operation again.",
                underlying: error
            )
        }
        return FailureReport(
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
        // A wrong selection throws a sentence the app wrote, so the words say what to select (ALERT review SF1c).
        if let importError = error as? MultipleSequenceAlignmentBundle.ImportError,
           case .malformedInput(let message) = importError,
           message == "Select one row and one or more alignment columns." {
            return FailureReport(
                failedStep: "Add the annotation",
                whatHappened: "The annotation needs one selected row and at least one selected column.",
                nextStep: "Select one row and the columns the annotation covers, then add it again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Add the annotation",
            whatHappened: "The new annotation was not saved in the alignment bundle.",
            nextStep: "Check that the alignment bundle can be written to, then add the annotation again.",
            underlying: error
        )
    }
}
