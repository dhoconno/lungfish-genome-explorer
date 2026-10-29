// DatabaseBrowserFailureReports.swift - Failure words for the database browser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit

/// The failure alerts of the database browser, each as a `FailureReport` whose error text goes only to the
/// details area (ALERT-PRESENTER, Phase 3.1).
enum DatabaseBrowserFailureReports {
    /// The three refusals `importAccessionList(at:)` words itself, matched by their exact sentence.
    static let downloadRunning = "Wait for the current download before importing accessions."
    static let noSRAAccessions = "No valid SRA accessions were found in the selected file."
    static let wrongSearchMode = "Accession lists are supported in SRA Runs and GenBank Nucleotide mode."

    /// Importing a file of accessions into the search box. A refusal the browser words itself keeps its fact in the
    /// body, and any other error is worded in general terms.
    static func importAccessionList(_ error: any Error) -> FailureReport {
        let step = "Import the accession list"
        if case DatabaseServiceError.invalidQuery(let reason) = error {
            switch reason {
            case downloadRunning:
                return FailureReport(
                    failedStep: step,
                    whatHappened: "A download is still running, so the accession list was not imported.",
                    nextStep: "Wait for the download to finish, then import the accession list again.",
                    underlying: error
                )
            case noSRAAccessions:
                return FailureReport(
                    failedStep: step,
                    whatHappened: reason,
                    nextStep: "Check that the file lists SRA run accessions, then import it again.",
                    underlying: error
                )
            case wrongSearchMode:
                return FailureReport(
                    failedStep: step,
                    whatHappened: reason,
                    nextStep: "Switch to SRA Runs or GenBank Nucleotide search, then import the accession list again.",
                    underlying: error
                )
            default:
                return FailureReport(
                    failedStep: step,
                    whatHappened: reason,
                    nextStep: "Check the file and the search type, then import the accession list again.",
                    underlying: error
                )
            }
        }
        return FailureReport(
            failedStep: step,
            whatHappened: "Lungfish could not read the accession list, so nothing was imported.",
            nextStep: "Check that the file can be read and holds a list of accessions, then import it again.",
            underlying: error
        )
    }
}
