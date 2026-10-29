// MainWindowFailureReports+PrimerExports.swift - Failure words for the primer exports of the main window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension MainWindowFailureReports {
    /// The error domain of the sentences `PrimerAnalysisExportDestination` throws when the project cannot take a
    /// new export folder (`Sources/LungfishOperations/PrimerAnalysisExportDestination.swift`, its `invalid` helper).
    static let primerExportDestinationErrorDomain = "PrimerAnalysisExport"

    /// The primer order export failed while it prepared the folder the order is written to (ALERT-C4).
    static func exportPrimerOrder(_ error: any Error) -> FailureReport {
        primerExportFolderFailure(
            failedStep: "Export the primer order",
            whatHappened: "Lungfish could not prepare a folder in the project for the primer order, so it was not exported.",
            again: "export the primer order again",
            error
        )
    }

    /// The primer FASTA bundle or reference amplicon export failed at the same step (ALERT-C4).
    static func exportPrimerAnalysisSelection(isPrimerFASTA: Bool, _ error: any Error) -> FailureReport {
        if isPrimerFASTA {
            return primerExportFolderFailure(
                failedStep: "Save the primer FASTA bundle",
                whatHappened: "Lungfish could not prepare a folder in the project for the primer FASTA bundle, so it was not saved.",
                again: "save the bundle again",
                error
            )
        }
        return primerExportFolderFailure(
            failedStep: "Extract the reference amplicon",
            whatHappened: "Lungfish could not prepare a folder in the project for the reference amplicon, so it was not extracted.",
            again: "extract the amplicon again",
            error
        )
    }

    /// Both exports build a `PrimerAnalysisExportDestination` first, before any operation row starts. It throws a
    /// sentence the app wrote, in the domain above, when the project folder is gone or replaced, or when an export
    /// folder is a link, and a file system error when the Analyses folder cannot be created. The app's sentence
    /// stays in the body with a next step that fits it, and the file system error goes to the details.
    private static func primerExportFolderFailure(
        failedStep: String, whatHappened: String, again: String, _ error: any Error
    ) -> FailureReport {
        if (error as NSError).domain == primerExportDestinationErrorDomain {
            return FailureReport(
                failedStep: failedStep,
                whatHappened: error.localizedDescription,
                nextStep: "Check that the project folder is still in place and that it and its Analyses folder are real folders, not links to other folders, then \(again).",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: failedStep,
            whatHappened: whatHappened,
            nextStep: "Check that the project folder can be written to and has free space, then \(again).",
            underlying: error
        )
    }
}
