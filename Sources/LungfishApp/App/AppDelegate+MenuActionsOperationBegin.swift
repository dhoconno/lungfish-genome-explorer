// AppDelegate+MenuActionsOperationBegin.swift - Operations panel registration for the UI test failure seed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

/// The begin helper for the failed row the `operations-failed-operation` UI
/// test scenario seeds (finding R4). It lives here, not beside its launch
/// site, so the baselined AppDelegate+MenuActions.swift does not grow
/// (scripts/ratchets/file-size.sh).
extension AppDelegate {
    /// Registers the seeded row and calls `launch` with the operation ID only
    /// when the row started. The row locks no bundle and carries no route
    /// context.
    ///
    /// This is a fixture, not an operation. `MainWindowNavigationXCUITests`
    /// opens the Operations panel, presses the report button on the failed
    /// row and checks that the GitHub issue URL names the title below.
    ///
    /// CLI parity gap. No run stands behind the row, so its command is a fixed
    /// string in the shape of a classification command. It is not a command
    /// that `lungfish-cli` accepts, because `conda classify` has no `--reads`
    /// option. The closest real command is `conda classify` with its input
    /// files and `--db`.
    @discardableResult
    static func beginOperationsPanelFailureSeedOperation(
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "UI test failed operation",
            detail: "Preparing deterministic failure",
            operationType: .classification,
            cliCommand: "\(CLICommandIdentity.executableName) conda classify --reads '~/ui-test/R1.fastq.gz'"
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Seeds the failed row the `operations-failed-operation` scenario shows,
    /// reporting through `reporter` so a test can check the finished row.
    static func seedOperationsPanelFailure(on reporter: any OperationReporting = OperationCenter.shared) {
        Self.beginOperationsPanelFailureSeedOperation(reporter: reporter) { operationID in
            reporter.log(
                id: operationID,
                level: .info,
                message: "UI test seeded operation"
            )
            _ = reporter.fail(
                id: operationID,
                detail: "Deterministic failure used by XCUI",
                errorMessage: "UI test failure",
                errorDetail: "This fixture exercises the Operations panel GitHub issue action."
            )
        }
    }
}
