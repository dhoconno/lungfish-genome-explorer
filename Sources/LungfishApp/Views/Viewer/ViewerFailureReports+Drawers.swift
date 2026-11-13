// ViewerFailureReports+Drawers.swift - Failure words for the FASTQ and annotation drawers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension ViewerFailureReports {
    /// The barcode scout of the FASTQ drawer stopped (ALERT-C4). The scout starts no Operations row. It throws
    /// `DemultiplexError.inputFileNotFound` when the FASTQ file is gone, `emptyAdapterSequences` or
    /// `ambiguousAdapterSequences` from its adapter check before any search tool starts (W-18, so the body says no search
    /// ran and gives the kit's cause), `kitSequencesUnderCheck` or `definitionHoldsKitSequencesUnderCheck` when the
    /// kit's built-in sequences are being checked (FIX-IDT, same words), and otherwise the search tool's failure, whose
    /// text goes to the details.
    /// `kit` gives the way out for its platform: an Illumina or Element kit is counted from the read names, and Detect
    /// cannot search an Ultima or MGI kit, so for those the words send no one back to Detect (DETECT-WAYOUT-CIRCLE, UX's
    /// condition 4 of `S2-R2-UX.md:33`).
    static func detectBarcodes(_ error: any Error, kit: BarcodeKitDefinition? = nil) -> FailureReport {
        let failedStep = "Detect the barcodes in the FASTQ file"
        let platform = kit?.platform
        if let demultiplexError = error as? DemultiplexError {
            switch demultiplexError {
            case .readNamesCarryNoIndex:
                return FailureReport(
                    failedStep: failedStep,
                    whatHappened: "Detect Barcodes found no index in the read names of this file.",
                    nextStep: readNameWayOut,
                    underlying: error
                )
            case .emptyAdapterSequences where platform == .ultima || platform == .mgi,
                 .ambiguousAdapterSequences where platform == .ultima || platform == .mgi:
                return FailureReport(
                    failedStep: failedStep,
                    whatHappened: "Detect Barcodes cannot search Ultima or MGI kits.",
                    nextStep: readNameWayOut,
                    underlying: error
                )
            case .inputFileNotFound:
                return FailureReport(
                    failedStep: failedStep,
                    whatHappened: "Lungfish could not find the FASTQ file, so no barcodes were detected.",
                    nextStep: "Select the FASTQ bundle in the sidebar again, then detect the barcodes again.",
                    underlying: error
                )
            case .emptyAdapterSequences(let kitName):
                return FailureReport(
                    failedStep: failedStep,
                    whatHappened: "No search was run, because Lungfish could not build any barcode sequences to search for from the kit \"\(kitName)\". No barcodes were detected and no files changed.",
                    nextStep: kitWayOut,
                    underlying: error
                )
            case .ambiguousAdapterSequences(let kitName):
                return FailureReport(
                    failedStep: failedStep,
                    whatHappened: "No search was run, because two barcodes of the kit \"\(kitName)\" give the same search sequence, so their reads could not be told apart. No barcodes were detected and no files changed.",
                    nextStep: kitWayOut,
                    underlying: error
                )
            case .kitSequencesUnderCheck(let kitName), .definitionHoldsKitSequencesUnderCheck(let kitName):
                return FailureReport(
                    failedStep: failedStep,
                    whatHappened: "No search was run, because the built-in sequences for the kit \"\(kitName)\" are being checked and Lungfish does not use them for now. No barcodes were detected and no files changed.",
                    nextStep: kitWayOut,
                    underlying: error
                )
            default:
                break
            }
        }
        return FailureReport(
            failedStep: failedStep,
            whatHappened: "The barcode search stopped before it finished, so no barcodes were detected.",
            nextStep: "Check that the FASTQ file is complete and can be read, then detect the barcodes again.",
            underlying: error
        )
    }

    /// What to try when the kit gave the scout nothing to search for. The FASTQ file is not the cause, and the details
    /// hold the kit's own message.
    private static let kitWayOut = "If you used a different kit, choose it and detect the barcodes again. Otherwise run Demultiplex Barcodes from the FASTQ operations dialog with a Custom Definition of the barcode sequences from your index sheet. Show Details has the full message."

    /// The way out for a kit whose index sits in the read names or in separate index reads, where another kit would
    /// refuse the same way (UX, `S33-R1-UX.md` D1c).
    private static let readNameWayOut = "For barcodes inside the reads, run Demultiplex Barcodes from the FASTQ operations dialog with a Custom Definition. Show Details has the full message."

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
