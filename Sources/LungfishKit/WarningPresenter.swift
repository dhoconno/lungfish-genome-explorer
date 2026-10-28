// WarningPresenter.swift - Shared beep+NSAlert warning helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

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
///
/// Since Phase 3.1 (ALERT-PRESENTER) this is a shim. A site that shows a
/// caught error builds a `FailureReport` and calls `FailurePresenter`, and
/// `present(title:message:in:)` forwards its alert to the same presentation
/// path for warnings whose words are already plain.
public enum WarningPresenter {
    /// Presents a warning alert as a sheet on `window`, or as a modal alert
    /// when no window is available. Does NOT beep —
    /// callers that want the system alert sound call `NSSound.beep()`
    /// themselves at the failure site, matching the pre-existing per-VC
    /// convention where not every warning is preceded by a beep.
    @MainActor
    public static func present(title: String, message: String, in window: NSWindow?) {
        FailurePresenter.show(alert(title: title, message: message), in: window, completion: nil)
    }

    /// The warning alert `present` shows, built without a sheet for tests.
    @MainActor
    static func alert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        return alert
    }
}
