// LeftoverOperationsGuard.swift - Test helpers for the rows a test leaves on the shared OperationCenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishGenotypeUI
import LungfishKit

/// An error whose words name the operations an earlier test left running.
struct LeftoverOperationsError: Error, CustomStringConvertible {
    let description: String
}

extension OperationCenter {
    /// Fails at once, naming each active row, when an earlier test left an operation running on this center.
    ///
    /// The quit path (`AppDelegate.applicationShouldTerminate`) and the window close path ask to confirm first when
    /// an operation is running, and the sheet they open waits for a click, so a row an earlier test left Running
    /// keeps a test of those paths from the code it checks. A process that runs every class of the bundle (the full
    /// tier) carries such a row from the class that left it to the end.
    @MainActor
    func requireNoActiveOperationsForTest() throws {
        let running = activeItems.map { "\($0.title) (\($0.operationType), \($0.state.rawValue))" }
        guard running.isEmpty else {
            throw LeftoverOperationsError(description: "An earlier test left \(running.count) operation(s) running in "
                + "OperationCenter.shared: \(running.joined(separator: ", ")). The quit and window-close warnings would wait "
                + "for a click, so this class stops here. Finish the operation in the test that began it.")
        }
    }

    /// Ends the row when it is still active, then removes it. `clearItem` alone leaves an active row in place.
    @MainActor
    func finishAndClearForTest(id: UUID) {
        _ = complete(id: id, detail: "Test finished")
        clearItem(id: id)
    }
}

/// Fails at once when an earlier test left a genotype comment or review saving or waiting for its workbook.
///
/// Quit waits for such an edit up to its deadline and then opens `GenotypeEditQuitConfirmation`, whose sheet waits for
/// a click, so a count an earlier test left up keeps a test of the quit path from the code it checks.
@MainActor
func requireNoPendingAnnotationEditsForTest() throws {
    guard GenotypeResultViewController.isSavingAnnotationEdits else { return }
    throw LeftoverOperationsError(description: "An earlier test left a genotype comment or review saving or waiting for "
        + "its workbook. The quit path would wait 15 seconds and then open a sheet that waits for a click, so this class "
        + "stops here. Finish the edit in the test that began it.")
}
