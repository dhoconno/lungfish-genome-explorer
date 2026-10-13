// NoProjectAlertPresenter.swift - Where the No Project Open refusal of a classifier launch reaches the screen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// Shows the `No Project Open` refusal of a classifier launch (Phase 2.10 panel decision A4).
///
/// A launch from a project window has a window to put the sheet on. A Tools menu item chosen with
/// no project window open has none, and the refusal still has to tell the user why nothing
/// started. The live presenter puts a sheet on the window it is given and shows an application-modal
/// alert with none. A test binds a recording presenter through
/// ``AppDelegate/NoProjectPresenterSeam``, because an application-modal alert in a unit test waits
/// for a click that never comes.
protocol NoProjectAlertPresenting: Sendable {
    /// Shows `title` and `message` on `window`, or application-modal when `window` is nil.
    @MainActor func present(title: String, message: String, on window: NSWindow?)
}

/// The presenter the app runs with.
///
/// The application-modal alert goes through `NSApp.presentError`, as
/// ``ProjectWriteGatePresenter`` and ``AssemblyRuntimePreflight`` do when they find no window,
/// because the project rules forbid calling `runModal` (agents/process/PROJECT-LEAD-AGENT.md).
struct LiveNoProjectAlertPresenter: NoProjectAlertPresenting {
    enum Mode: Equatable {
        case sheet
        case applicationModal
    }

    static func mode(hasWindow: Bool) -> Mode {
        hasWindow ? .sheet : .applicationModal
    }

    @MainActor func present(title: String, message: String, on window: NSWindow?) {
        if Self.mode(hasWindow: window != nil) == .sheet, let window {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(Refusal(title: title, message: message))
        }
    }

    /// The refusal as an error, which AppKit shows as an application-modal alert holding the title
    /// in bold over the message.
    private struct Refusal: LocalizedError {
        let title: String
        let message: String

        var errorDescription: String? { title }
        var recoverySuggestion: String? { message }
    }
}

extension AppDelegate {
    /// The presenter the `No Project Open` refusal reads (Phase 2.10 panel decision A4).
    ///
    /// The default is the live presenter. Only a test binds another, with `$presenter.withValue`,
    /// to record what the refusal hands over. The presenter is task-local, so nothing can assign
    /// it, and the refusal reads it on the main actor in the call that launches.
    enum NoProjectPresenterSeam {
        @TaskLocal static var presenter: any NoProjectAlertPresenting = LiveNoProjectAlertPresenter()
    }
}
