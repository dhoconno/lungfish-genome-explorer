// TemporaryFailureReportStore.swift - Keeps failure reports from tests out of the user's logs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension OperationFailureReportStore {
    /// A store rooted in a shared temporary directory.
    ///
    /// Every failed operation writes a report, and the store an
    /// `OperationCenter` starts with writes into the user's `~/Library/Logs`.
    /// A test that can fail an operation installs this store first, on its own
    /// center or on `OperationCenter.shared`. The retention limit keeps the
    /// directory small.
    public static func temporaryForTesting() -> OperationFailureReportStore {
        OperationFailureReportStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("LungfishTestFailureReports", isDirectory: true)
        )
    }
}

extension OperationCenter {
    /// Gives the shared center a temporary report store for the rest of this
    /// test process.
    ///
    /// Call it from `setUp` in any suite whose tests fail an operation on
    /// `OperationCenter.shared`, directly or through app code. It is never
    /// undone, because an operation a test started can fail after that test
    /// has finished.
    @MainActor
    public static func useTemporaryFailureReportsForTesting() {
        shared.failureReportStore = .temporaryForTesting()
    }
}
