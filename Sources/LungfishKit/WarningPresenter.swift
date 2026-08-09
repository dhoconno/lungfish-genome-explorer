// WarningPresenter.swift - Shared beep+NSAlert warning helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A generic, localizable error used to route a title/message pair through
/// `NSApp.presentError` when no window is available for a sheet. Internal
/// implementation detail of `WarningPresenter.present` — not part of its
/// public surface.
struct WarningPresenterError: LocalizedError {
    let title: String
    let message: String

    var errorDescription: String? { title }
    var recoverySuggestion: String? { message }
}

/// Shared beep+NSAlert warning presentation, extracted (round-2 structural
/// backlog item 1, 2026-08-08 repo review fix campaign) from three
/// hand-copied `presentWarning(title:message:)` private methods
/// (`AssemblyResultViewController`, `NaoMgsResultViewController`,
/// `TaxonomyViewController` — flagged E3).
///
/// Call sites keep their own `warningPresenter: ((String, String) -> Void)?`
/// test seam (a stored property on the view controller) — this helper only
/// centralizes the *default* presentation behavior that seam falls back to,
/// so existing tests that set `warningPresenter` to a spy continue to work
/// unchanged.
public enum WarningPresenter {
    /// Presents a warning alert as a sheet on `window`, or via
    /// `NSApp.presentError` when no window is available. Does NOT beep —
    /// callers that want the system alert sound call `NSSound.beep()`
    /// themselves at the failure site, matching the pre-existing per-VC
    /// convention where not every warning is preceded by a beep.
    @MainActor
    public static func present(title: String, message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(WarningPresenterError(title: title, message: message))
        }
    }
}
