// AppTestStateChecks.swift - The test-state check that reads LungfishApp state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
@testable import LungfishApp

/// The check of ``TestStateObserver`` that needs LungfishApp's own types (Phase 3.1 ruling QA-RELEASE-LOOP,
/// section 4). The row and window checks live in `Tests/Support/LungfishKitTestSupport/KitTestStateChecks.swift`, so
/// all three app-hosted bundles run them. The bootstrap constructor
/// (`Tests/Support/LungfishTestObserverBootstrap/bootstrap.c`) sends `install` when this bundle loads, before its
/// first case.
///
/// `ProjectTaskTerminationRegistry.hasPendingTasks` is what the quit path waits on. Nothing can end those tasks at
/// once, so the restore leaves them, and the next case starts with them in its snapshot.
@objc(LGEAppTestStateChecks)
final class AppTestStateChecks: NSObject {
    static let names = ["pending project tasks"]

    @objc static func install() {
        TestStateObserver.register(pendingProjectTasksCheck())
    }

    static func pendingProjectTasksCheck() -> TestStateCheck {
        TestStateCheck(
            name: names[0], noun: "pending project task set", comparison: .newKeys,
            snapshot: {
                ProjectTaskTerminationRegistry.hasPendingTasks ? ["pending": "ProjectTaskTerminationRegistry.hasPendingTasks"] : [:]
            },
            restore: { _, _ in })
    }
}
