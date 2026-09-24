// ResultExportCoordinator.swift - shared export-failure presentation for result viewers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Presents an export failure to the user. Injectable so tests can assert a
/// failure was surfaced without driving real `NSAlert` UI (2026-09-23
/// best-practices audit, UX-02: several classifier export paths logged
/// failures and showed nothing to the user, leaving the user to believe a
/// file was written when it was not).
@MainActor
public protocol ExportFailurePresenting {
    func presentExportFailure(title: String, message: String, in window: NSWindow?)
}

/// Default presenter: beeps and shows an `NSAlert` sheet on `window`
/// (falling back to `NSApp.presentError` when no window is available),
/// matching the pattern Kraken2 (`TaxonomyViewController.presentWarning`)
/// and 12S (`TwelveSAmpliconResultViewController.presentExportError`)
/// already used before this helper existed.
@MainActor
public struct DefaultExportFailurePresenter: ExportFailurePresenting {
    public init() {}

    public func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        NSSound.beep()
        WarningPresenter.present(title: title, message: message, in: window)
    }
}

/// Adapts an existing per-view-controller `(title, message) -> Void`
/// warning-presenter closure seam (Kraken2's `warningPresenter`, the pattern
/// three viewers hand-rolled before `WarningPresenter` existed) onto
/// `ExportFailurePresenting`, so those viewers can route through
/// `ResultExportCoordinator` without breaking existing tests that set the
/// closure seam directly.
@MainActor
public struct WarningPresenterExportAdapter: ExportFailurePresenting {
    private let present: (String, String) -> Void

    public init(present: @escaping (String, String) -> Void) {
        self.present = present
    }

    public func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        present(title, message)
    }
}

/// Shared coordinator for "write a result export, and if it fails, tell the
/// user" — the pattern every classifier result viewer's Export menu should
/// follow. Callers keep their own save-panel and write-content code; this
/// type only standardizes the failure-reporting half, which is what had
/// drifted (silent `logger.error` only, in EsViritu, TaxTriage's three
/// export paths, NAO-MGS and NVD).
///
/// Usage from a save-panel completion handler:
/// ```swift
/// do {
///     try writeSomething(to: url)
/// } catch {
///     ResultExportCoordinator.reportFailure(
///         fileName: url.lastPathComponent,
///         error: error,
///         window: view.window,
///         presenter: exportFailurePresenter
///     )
/// }
/// ```
public enum ResultExportCoordinator {
    /// Default title used across every migrated export path, matching the
    /// wording Kraken2 already used ("Export Failed").
    public static let defaultFailureTitle = "Export Failed"

    /// Reports an export failure: presents an alert (or the injected test
    /// seam) with a consistent message. Does not itself log — callers keep
    /// their existing `logger.error` call alongside this for the Operations
    /// log trail.
    @MainActor
    public static func reportFailure(
        fileName: String,
        error: Error,
        window: NSWindow?,
        title: String = ResultExportCoordinator.defaultFailureTitle,
        presenter: ExportFailurePresenting = DefaultExportFailurePresenter()
    ) {
        let message = "Could not write \(fileName): \(error.localizedDescription)"
        presenter.presentExportFailure(title: title, message: message, in: window)
    }
}
