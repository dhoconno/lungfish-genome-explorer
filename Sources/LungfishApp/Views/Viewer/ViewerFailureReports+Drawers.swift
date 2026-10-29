// ViewerFailureReports+Drawers.swift - Failure words for the FASTQ and annotation drawers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

extension ViewerFailureReports {
    /// The barcode scout of the FASTQ drawer stopped (ALERT-C4). The scout starts no Operations row. It throws
    /// `DemultiplexError.inputFileNotFound` when the FASTQ file is gone, and otherwise the search tool's failure,
    /// whose text goes to the details.
    static func detectBarcodes(_ error: any Error) -> FailureReport {
        if let demultiplexError = error as? DemultiplexError, case .inputFileNotFound = demultiplexError {
            return FailureReport(
                failedStep: "Detect the barcodes in the FASTQ file",
                whatHappened: "Lungfish could not find the FASTQ file, so no barcodes were detected.",
                nextStep: "Select the FASTQ bundle in the sidebar again, then detect the barcodes again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Detect the barcodes in the FASTQ file",
            whatHappened: "The barcode search stopped before it finished, so no barcodes were detected.",
            nextStep: "Check that the FASTQ file is complete and can be read, then detect the barcodes again.",
            underlying: error
        )
    }

    /// The command that deletes the annotation rows failed. Its Operations row is failed just before this
    /// alert, so the panel holds the command's message.
    static func deleteAnnotations(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Delete the annotations",
            whatHappened: "The command that deletes the annotations stopped before it finished, so they may still be in the bundle.",
            nextStep: "Open the Operations panel to read the log of this run, then delete the annotations again.",
            underlying: error
        )
    }

    /// The annotations were deleted and their row completed, and then the viewer could not reload the bundle.
    static func reloadAfterAnnotationDeletion(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Reload the bundle after deleting the annotations",
            whatHappened: "The annotations were deleted from the bundle, but the viewer could not reload the bundle to show the change.",
            nextStep: "Select the bundle in the sidebar again to reload it. If it still does not open, check that the bundle folder is in the project.",
            underlying: error
        )
    }

    /// The command that deletes an annotation track failed. The Operations row of the run is failed just before
    /// this alert, so its panel holds the command's message.
    static func deleteAnnotationTrack(_ trackName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Delete the \(trackName) annotation track",
            whatHappened: "The command that deletes the track stopped before it finished, so the track may still be in the bundle.",
            nextStep: "Open the Operations panel to read the log of this run, then delete the track again.",
            underlying: error
        )
    }

    /// The track was deleted and its row completed, and then the viewer could not reload the bundle.
    static func reloadAfterAnnotationTrackDeletion(_ trackName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Reload the bundle after deleting the \(trackName) annotation track",
            whatHappened: "The track was deleted from the bundle, but the viewer could not reload the bundle to show the change.",
            nextStep: "Select the bundle in the sidebar again to reload it. If it still does not open, check that the bundle folder is in the project.",
            underlying: error
        )
    }
}
