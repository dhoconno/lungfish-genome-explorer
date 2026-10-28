// OperationsPanelFailureReports.swift - Failure words for the Operations panel's row actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the Operations panel shows, each as a `FailureReport`
/// whose error text goes only to the details area (ALERT-PRESENTER, Phase 3.1).
enum OperationsPanelFailureReports {
    static func removePartialOutput(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Remove the partial output",
            whatHappened: "The files the stopped run left behind are still in the project.",
            nextStep: "Check that the project folder can be written to, then remove the partial output again, or delete the run's folder in the Finder.",
            underlying: error
        )
    }

    static func writeOperationLog(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Write the operation log",
            whatHappened: "Lungfish could not create a local log file for this operation.",
            nextStep: "Check that the disk has free space, then try again. Copy Log puts the same entries on the clipboard.",
            underlying: error
        )
    }
}
