// AppTestStateChecks.swift - The test-state checks that read LungfishKit, AppKit and LungfishApp state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// The checks of ``TestStateObserver`` that need LungfishKit, AppKit or LungfishApp (Phase 3.1 ruling
/// QA-RELEASE-LOOP, section 4). They live in this bundle because LungfishTestSupport imports no Kit module. The
/// bootstrap constructor (`Tests/Support/LungfishTestObserverBootstrap/bootstrap.c`) sends `install` when this
/// bundle loads, before its first case.
///
/// - The active rows of `OperationCenter.shared`, which block the quit and window-close paths. The restore ends and
///   clears each new row, as `finishAndClearForTest` does.
/// - The windows that are visible and can become key. The restore orders each new one out.
/// - `ProjectTaskTerminationRegistry.hasPendingTasks`, which the quit path waits on. Nothing can end those tasks
///   at once, so the restore leaves them, and the next case starts with them in its snapshot.
@objc(LGEAppTestStateChecks)
final class AppTestStateChecks: NSObject {
    static let names = ["operation rows", "visible key windows", "pending project tasks"]

    @objc static func install() {
        TestStateObserver.register(operationRowsCheck())
        TestStateObserver.register(visibleWindowsCheck())
        TestStateObserver.register(pendingProjectTasksCheck())
    }

    static func operationRowsCheck() -> TestStateCheck {
        TestStateCheck(
            name: names[0], noun: "active operation row", comparison: .newKeys,
            snapshot: {
                OperationCenter.shared.activeItems.reduce(into: [:]) { rows, item in
                    rows[item.id.uuidString] = "\"\(item.title)\" (\(item.operationType), \(item.state.rawValue))"
                }
            },
            restore: { keys, _ in
                for id in keys.compactMap(UUID.init(uuidString:)) {
                    OperationCenter.shared.finishAndClearForTest(id: id)
                }
            })
    }

    static func visibleWindowsCheck() -> TestStateCheck {
        TestStateCheck(
            name: names[1], noun: "visible key window", comparison: .newKeys,
            snapshot: {
                (NSApp?.windows ?? []).filter { $0.isVisible && $0.canBecomeKey }.reduce(into: [:]) { shown, window in
                    shown[String(window.windowNumber)] = "\"\(window.title)\" (\(type(of: window)))"
                }
            },
            restore: { keys, _ in
                for window in NSApp?.windows ?? [] where keys.contains(String(window.windowNumber)) {
                    window.orderOut(nil)
                }
            })
    }

    static func pendingProjectTasksCheck() -> TestStateCheck {
        TestStateCheck(
            name: names[2], noun: "pending project task set", comparison: .newKeys,
            snapshot: {
                ProjectTaskTerminationRegistry.hasPendingTasks ? ["pending": "ProjectTaskTerminationRegistry.hasPendingTasks"] : [:]
            },
            restore: { _, _ in })
    }
}
