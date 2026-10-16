// AppDelegate+ImportAlerts.swift - How File > Import Files... ends, and the alerts of an import that cannot start
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// How a File > Import Files... request ended, once every file it tracks has ended (Phase 2.11 lane U62).
///
/// The request keeps a count of the files that succeeded and the files that failed. Only a failure
/// earns the alert.
struct ImportFilesOutcome: Equatable, Sendable {
    /// The words of the alert a request that ended with failures shows.
    struct Alert: Equatable, Sendable {
        let title: String
        let message: String
    }

    let succeeded: Int
    let failed: Int
    /// The files the user cancelled. A cancelled file is neither a success nor a failure, so the
    /// alert neither counts nor names it.
    let cancelled: Int

    init(succeeded: Int, failed: Int, cancelled: Int = 0) {
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
    }

    /// The outcome of a request whose tracker filed each cancelled file as a failed one, because the
    /// file posted `success: false`.
    init(update: SidebarImportRequestTrackerUpdate, cancelled: Int) {
        self.init(succeeded: update.succeeded, failed: update.failed - cancelled, cancelled: cancelled)
    }

    /// The alert this outcome shows, or nil when no file failed.
    var alert: Alert? {
        guard failed > 0 else { return nil }
        return Alert(title: "Import Completed with Errors", message: "\(succeeded) succeeded, \(failed) failed.")
    }
}

/// Counts the files of one File > Import Files... request that the user cancelled.
///
/// The request's tracker files every `success: false` as a failed file, and the outcome takes the
/// cancelled ones back out. Only the main run loop touches it, as it does the tracker.
final class ImportFilesCancelTally: @unchecked Sendable {
    private(set) var count = 0

    func add(_ wasCancelled: Bool) {
        if wasCancelled { count += 1 }
    }
}

/// Shows how a File > Import Files... request ended.
///
/// The live presenter puts the alert on the window of the import as a sheet and shows nothing when
/// the outcome has no alert or the import has no window. A test binds a recording presenter through
/// ``AppDelegate/ImportFilesOutcomeSeam``, which also tells it that a request has ended, so a test
/// that expects no alert waits for the end and then reads that there is none.
protocol ImportFilesOutcomePresenting: Sendable {
    /// Called once for each request, on the main actor, when its last file has ended.
    @MainActor func present(_ outcome: ImportFilesOutcome, on window: NSWindow?)
}

/// The presenter the app runs with.
struct LiveImportFilesOutcomePresenter: ImportFilesOutcomePresenting {
    @MainActor func present(_ outcome: ImportFilesOutcome, on window: NSWindow?) {
        guard let content = outcome.alert, let window else { return }
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.applyLungfishBranding()
        alert.beginSheetModal(for: window)
    }
}

extension AppDelegate {
    /// The presenter the end of a File > Import Files... request reads.
    ///
    /// The default is the live presenter. Only a test binds another, with `$presenter.withValue`.
    /// The request reads it in the call that starts the import, since the end comes later on the
    /// main run loop, after the binding has gone.
    enum ImportFilesOutcomeSeam {
        @TaskLocal static var presenter: any ImportFilesOutcomePresenting = LiveImportFilesOutcomePresenter()
    }
}
