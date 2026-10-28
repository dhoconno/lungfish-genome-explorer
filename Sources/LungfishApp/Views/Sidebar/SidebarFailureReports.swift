// SidebarFailureReports.swift - Failure words for the sidebar's file actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the sidebar shows, each as a `FailureReport` whose
/// error text goes only to the details area (ALERT-PRESENTER, Phase 3.1).
enum SidebarFailureReports {
    static func saveImportedSampleMetadata(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Save the imported sample metadata",
            whatHappened: "Lungfish read the metadata file but could not write the metadata into the project folder.",
            nextStep: "Check that the project folder can be written to and that the disk has free space, then import the metadata file again.",
            underlying: error
        )
    }

    static func createFolder(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Create the folder",
            whatHappened: "The new folder was not made in the project.",
            nextStep: "Check that the project folder can be written to, then create the folder again.",
            underlying: error
        )
    }

    static func rename(_ oldName: String, to newName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Rename \(oldName)",
            whatHappened: "The item keeps its old name.",
            nextStep: "Check that no other item in the folder is named \(newName) and that the project folder can be written to, then rename it again.",
            underlying: error
        )
    }

    static func moveItems(_ failures: [(name: String, error: any Error)]) -> FailureReport {
        FailureReport(
            failedStep: "Move the selected items",
            whatHappened: "Lungfish could not move \(listOfNames(failures.map(\.name))).",
            nextStep: "Check that the destination folder can be written to, then move them again.",
            itemErrors: failures
        )
    }

    static func deleteItems(_ failures: [(name: String, error: any Error)]) -> FailureReport {
        FailureReport(
            failedStep: "Delete the selected items",
            whatHappened: "Lungfish could not delete \(listOfNames(failures.map(\.name))).",
            nextStep: "Check that the project folder can be written to and that no other app is using these items, then delete them again.",
            itemErrors: failures
        )
    }

    /// The names as one phrase, "a, b and c" in the user's language.
    private static func listOfNames(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }
}
