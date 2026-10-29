// KitTestStateChecks.swift - The row and window checks of the test-state observer, for the app-hosted bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit
import LungfishTestSupport

/// The checks of ``TestStateObserver`` that read LungfishKit and AppKit state (Phase 3.1 ruling QA-RELEASE-LOOP,
/// section 4). They live here because LungfishTestSupport imports no Kit module, and all three app-hosted bundles
/// link this target. The bootstrap constructor (`Tests/Support/LungfishTestObserverBootstrap/bootstrap.c`) sends
/// `install` when a bundle loads, and the checks register only in those three bundles, so every other bundle keeps
/// the defaults, environment and directory checks alone, as the ruling says.
///
/// - The active rows of `OperationCenter.shared`, which block the quit and window-close paths. The restore ends and
///   clears each new row, as `finishAndClearForTest` does.
/// - The windows that are visible and can become key. The restore orders each new one out.
@objc(LGEKitTestStateChecks)
public final class KitTestStateChecks: NSObject {
    public static let names = ["operation rows", "visible key windows"]
    /// The bundles that run the app's views and so get every check.
    public static let appHostedBundles: Set<String> = ["LungfishAppTests", "LungfishAppViewTests", "LungfishAppWorkflowTests"]

    @objc public static func install() {
        let bundle = Bundle(for: KitTestStateChecks.self).bundleURL.deletingPathExtension().lastPathComponent
        guard appHostedBundles.contains(bundle) else { return }
        TestStateObserver.register(operationRowsCheck())
        TestStateObserver.register(visibleWindowsCheck())
    }

    public static func operationRowsCheck() -> TestStateCheck {
        TestStateCheck(
            name: names[0], noun: "active operation row", comparison: .newKeys,
            snapshot: {
                OperationCenter.shared.activeItems.reduce(into: [:]) { rows, item in
                    rows[item.id.uuidString] = "\"\(item.title)\" (\(item.operationType), \(item.state.rawValue))"
                }
            },
            restore: { keys, _ in
                // As `finishAndClearForTest` does (`Tests/LungfishAppTests/LeftoverOperationsGuard.swift`), since
                // `clearItem` alone leaves an active row in place.
                for id in keys.compactMap(UUID.init(uuidString:)) {
                    _ = OperationCenter.shared.complete(id: id, detail: "Test finished")
                    OperationCenter.shared.clearItem(id: id)
                }
            })
    }

    public static func visibleWindowsCheck() -> TestStateCheck {
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
}
