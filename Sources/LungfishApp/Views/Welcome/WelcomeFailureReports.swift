// WelcomeFailureReports.swift - Failure words for the welcome window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the welcome window shows, each as a `FailureReport`
/// whose error text goes only to the details area (ALERT-PRESENTER, Phase 3.1).
enum WelcomeFailureReports {
    static func createProject(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Create the project",
            whatHappened: "The project folder was not made.",
            nextStep: "Check that the folder you chose can be written to and has no project with the same name, then create the project again.",
            underlying: error
        )
    }
}
