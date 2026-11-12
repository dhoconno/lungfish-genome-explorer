// AppMemoryGuard.swift - At its memory share the app cancels its work and says why
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishKit

/// Reads the app's own footprint every ``ProcessMemoryShare/pollInterval``. When it reaches the share, half of this
/// Mac's memory, the guard cancels every running operation and the load in flight of each open viewer, writes why as
/// an error line in each cancelled row and shows the same words once in an alert. It speaks again only after the
/// footprint fell below 90% of the share. A watchdog that stops a run says why
/// (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time).
@MainActor
final class AppMemoryGuard {
    /// An operation the guard can stop, by the title its row shows.
    struct RunningOperation: Equatable {
        let id: UUID
        let title: String
    }

    /// What the guard reads and does. Tests record them in place of the app's own.
    struct Actions {
        var runningOperations: @MainActor () -> [RunningOperation]
        /// Writes the words in the row and cancels it.
        var cancelOperation: @MainActor (UUID, String) -> Void
        /// Cancels the load in flight of each open viewer and returns how many it cancelled.
        var cancelLoads: @MainActor () -> Int
        var present: @MainActor (String) -> Void
    }

    static let shared = AppMemoryGuard()

    private let watch: ProcessMemoryWatch
    private let actions: Actions

    init(
        share: ProcessMemoryShare = ProcessMemoryShare(),
        readFootprint: @escaping @Sendable () -> UInt64? = { ProcessMemoryShare.currentFootprint() },
        actions: Actions = .live
    ) {
        watch = ProcessMemoryWatch(share: share, readFootprint: readFootprint)
        self.actions = actions
    }

    /// Reads the footprint every poll on the main queue.
    func start() {
        watch.start(queue: .main) { [weak self] footprint in
            Task { @MainActor in
                self?.stopWork(footprint: footprint)
            }
        }
    }

    /// Reads the footprint once, and stops the work when it reached the share.
    func check() {
        guard let footprint = watch.check() else { return }
        stopWork(footprint: footprint)
    }

    private func stopWork(footprint: UInt64) {
        let operations = actions.runningOperations()
        let loads = actions.cancelLoads()
        let words = Self.words(
            operations: operations.map(\.title), stoppedLoad: loads > 0, footprint: footprint, share: watch.share
        )
        for operation in operations {
            actions.cancelOperation(operation.id, words)
        }
        actions.present(words)
    }

    /// The words of a stop, naming what stopped, the footprint and this Mac's memory.
    static func words(operations: [String], stoppedLoad: Bool, footprint: UInt64, share: ProcessMemoryShare) -> String {
        let using = "LGE was using \(MemoryWords.bytes(footprint)) of memory, \(share.shareWords)"
        let stopped = operations + (stoppedLoad ? ["the load in the viewer"] : [])
        guard let last = stopped.last else {
            return "\(using), and no operation or load was running for it to stop. "
                + "Close windows you do not need, or quit and reopen LGE, so the Mac does not run out of memory."
        }
        let named = stopped.count == 1 ? last : stopped.dropLast().joined(separator: ", ") + " and " + last
        return "LGE stopped \(named) because \(using). It stops there so the Mac does not run out of memory. "
            + "Close windows you do not need, then run it again on fewer or smaller files, or on a Mac with more memory."
    }
}

extension AppDelegate {
    /// Starts the monitors that run for the life of the app, the one of BLAST searches in flight and the memory
    /// guard, which at half of the Mac's memory cancels the app's work and says why before the Mac runs out.
    /// `AppDelegate.swift` may not grow (`scripts/ratchets/file-size.sh`), so its launch calls this one line.
    func startLaunchMonitors() {
        BlastInFlightMonitor.shared.start()
        AppMemoryGuard.shared.start()
    }
}

extension AppMemoryGuard.Actions {
    /// The app's operations, its open viewers and an alert.
    static var live: AppMemoryGuard.Actions {
        AppMemoryGuard.Actions(
            runningOperations: {
                OperationCenter.shared.activeItems
                    .filter { $0.state == .running || $0.state == .waiting }
                    .map { AppMemoryGuard.RunningOperation(id: $0.id, title: $0.title) }
            },
            cancelOperation: { id, words in
                OperationCenter.shared.log(id: id, level: .error, message: words)
                OperationCenter.shared.cancel(id: id)
            },
            cancelLoads: {
                var cancelled = 0
                for case let controller as MainWindowController in NSApp.windows.compactMap(\.windowController) {
                    let split: MainSplitViewController? = controller.mainSplitViewController
                    guard let viewer = split?.viewerController, viewer.isViewLoaded else { continue }
                    let host = viewer.surfaceHost
                    guard let load = host.loadTask, host.lastOutcome == nil else { continue }
                    load.cancel()
                    cancelled += 1
                }
                return cancelled
            },
            present: { words in
                let title = "LGE Stopped Work to Save Memory"
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                    NSApp.presentError(MemoryStopNotice(title: title, message: words))
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = title
                alert.informativeText = words
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        )
    }
}

/// The notice as an error, which AppKit shows as an application-modal alert with the title over the words.
private struct MemoryStopNotice: LocalizedError {
    let title: String
    let message: String

    var errorDescription: String? { title }
    var recoverySuggestion: String? { message }
}
