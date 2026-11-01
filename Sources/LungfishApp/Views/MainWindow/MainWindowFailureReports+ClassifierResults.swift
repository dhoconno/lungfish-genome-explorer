// MainWindowFailureReports+ClassifierResults.swift - Failure words for a NAO-MGS or NVD result that does not open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension MainWindowFailureReports {
    /// The error domain of the sentences `displayNaoMgsResultFromSidebar` throws itself. Code 1 is a result folder with
    /// no manifest, code 2 one with no database file and code 3 a database in an older layout, which Lungfish does not
    /// rewrite while it opens a result (`MainSplitViewController+ClassifierDisplay.swift`).
    static let naoMgsDisplayErrorDomain = "NaoMgsDisplay"

    /// The error domain of the sentences `displayNvdResultFromSidebar` throws itself, code 1 for no manifest and code 2
    /// for no database file.
    static let nvdDisplayErrorDomain = "NvdDisplay"

    /// A NAO-MGS result did not open from the sidebar (ALERT-C5). A result folder that lacks a file, or holds a database
    /// in an older layout, takes the app's own cause and the step that fixes it. Any other error (an unreadable or damaged
    /// manifest, a database SQLite could not open) takes the general words, and its text goes to the details.
    static func openNaoMgsResult(named resultName: String, _ error: any Error) -> FailureReport {
        let bridged = error as NSError
        if bridged.domain == naoMgsDisplayErrorDomain, bridged.code == 3 {
            return FailureReport(
                failedStep: "Open the NAO-MGS result",
                whatHappened: "The NAO-MGS result \(quoted(resultName)) was saved in an older layout, and Lungfish does not change a result when it opens one.",
                nextStep: "Import the NAO-MGS result again, then select it in the sidebar.",
                underlying: error
            )
        }
        return openClassifierResult(tool: "NAO-MGS", domain: naoMgsDisplayErrorDomain, resultName: resultName, error)
    }

    /// An NVD result did not open from the sidebar (ALERT-C5), with the same two branches as the NAO-MGS words.
    static func openNvdResult(named resultName: String, _ error: any Error) -> FailureReport {
        openClassifierResult(tool: "NVD", domain: nvdDisplayErrorDomain, resultName: resultName, error)
    }

    private static func openClassifierResult(
        tool: String, domain: String, resultName: String, _ error: any Error
    ) -> FailureReport {
        let bridged = error as NSError
        if bridged.domain == domain, bridged.code == 1 || bridged.code == 2 {
            return FailureReport(
                failedStep: "Open the \(tool) result",
                whatHappened: "The \(tool) result folder \(quoted(resultName)) is missing a file Lungfish needs, so the result did not open.",
                nextStep: "Import the \(tool) result again, then select it in the sidebar.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Open the \(tool) result",
            whatHappened: "Lungfish could not read the \(tool) result folder \(quoted(resultName)), so the result did not open.",
            nextStep: "Check that the folder can be read, then select the result in the sidebar again. If it still does not open, import the \(tool) result again.",
            underlying: error
        )
    }

    private static func quoted(_ name: String) -> String {
        "\u{201C}\(name)\u{201D}"
    }
}
