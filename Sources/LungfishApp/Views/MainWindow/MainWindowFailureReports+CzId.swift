// MainWindowFailureReports+CzId.swift - Failure words for a CZ-ID result that does not open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension MainWindowFailureReports {
    /// A CZ-ID result did not open from the sidebar because its files could not be read. The words name the result
    /// and the next step, and the error's own text goes only to the details area.
    static func openCzIdResult(named resultName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Open the CZ-ID result",
            whatHappened: "Lungfish could not read the CZ-ID result folder \u{201C}\(resultName)\u{201D}, so the result did not open.",
            nextStep: "Check that the folder can be read, then select the result in the sidebar again. If it still does not open, import the CZ-ID result again.",
            underlying: error
        )
    }
}
