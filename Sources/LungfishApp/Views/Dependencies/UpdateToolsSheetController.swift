// UpdateToolsSheetController.swift - Presents the Update Tools sheet on a host window
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "UpdateToolsSheet")

public extension Notification.Name {
    /// Posted on the main thread after the Update Tools sheet finishes a run and is dismissed.
    ///
    /// The Welcome window listens so its required-setup gate re-evaluates without the user
    /// having to poke it, and the launch trigger listens so it can stamp the "we are current"
    /// defaults once the receipt agrees with the manifest.
    static let lungfishDependencyReconciliationDidFinish = Notification.Name(
        "com.lungfish.dependencyReconciliationDidFinish"
    )
}

/// Presents ``UpdateToolsSheet`` as a sheet, never as a modal session.
@MainActor
enum UpdateToolsSheetController {

    /// Whether a sheet is already up, so a second trigger (launch plus Plugin Manager) does
    /// not stack two of them on the same window.
    private(set) static var isPresenting = false

    /// Presents the sheet on `window`.
    ///
    /// - Parameters:
    ///   - onDismissWithoutRunning: Invoked when the user chose "Later" or "Quit". The caller
    ///     decides which of those it means, because only the caller knows whether the app can
    ///     keep running.
    static func present(
        plan: ReconciliationPlan,
        reconciler: DependencyReconciler,
        storageRoot: URL,
        on window: NSWindow,
        onDismissWithoutRunning: (() -> Void)? = nil,
        onFinished: ((DependencyReceipt?) -> Void)? = nil
    ) {
        guard !isPresenting else {
            logger.info("Update Tools sheet already presented; ignoring duplicate request")
            return
        }
        isPresenting = true

        let viewModel = UpdateToolsSheetViewModel(
            plan: plan,
            reconciler: reconciler,
            freeSpaceProvider: Self.freeSpaceProvider(for: storageRoot)
        )

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Update Tools"
        panel.isReleasedWhenClosed = false

        let sheet = UpdateToolsSheet(
            viewModel: viewModel,
            onDismiss: {
                isPresenting = false
                window.endSheet(panel)
                onDismissWithoutRunning?()
            },
            onFinish: {
                isPresenting = false
                window.endSheet(panel)
                let receipt = viewModel.resultReceipt
                onFinished?(receipt)
                NotificationCenter.default.post(
                    name: .lungfishDependencyReconciliationDidFinish,
                    object: nil
                )
            }
        )

        let hostingController = NSHostingController(rootView: sheet)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 500, height: 480))
        window.beginSheet(panel) { _ in
            // Backstop for dismissals that did not go through the sheet's own buttons, such as
            // the host window closing underneath it. Without this the guard would latch on and
            // refuse every later presentation.
            MainActor.assumeIsolated { isPresenting = false }
        }
    }

    /// A window suitable to hang the sheet on: the key window if there is one, else any
    /// visible window, else nil (the app has not put anything on screen yet).
    static func hostWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.isVisible {
            return key
        }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }

    /// Free bytes on the volume that holds `storageRoot`, for the headroom check.
    ///
    /// Walks up to the nearest existing ancestor because the root itself may not exist yet on
    /// a first launch, and `URLResourceValues` needs a path that is really there.
    static func freeSpaceProvider(for storageRoot: URL) -> @Sendable () -> Int64? {
        let path = storageRoot.standardizedFileURL
        return {
            var candidate = path
            while !FileManager.default.fileExists(atPath: candidate.path) {
                let parent = candidate.deletingLastPathComponent().standardizedFileURL
                guard parent != candidate else { return nil }
                candidate = parent
            }
            let values = try? candidate.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            return values?.volumeAvailableCapacityForImportantUsage
        }
    }
}
