// TaxonomyReadExtractionAction+Presenters.swift - The extraction sheet's presenter seams, bundle-name stamp and task box
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

// MARK: - Test-seam protocols

/// Test seam for presenting `NSAlert` on a window.
@MainActor
public protocol AlertPresenting {
    func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse
}

/// Test seam for presenting an `NSSharingServicePicker`.
@MainActor
public protocol SharingServicePresenting {
    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge)
}

// MARK: - Default implementations

@MainActor
struct DefaultAlertPresenter: AlertPresenting {
    func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
        // macOS 26 rule: use beginSheetModal, never runModal.
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}

@MainActor
struct DefaultSharingServicePresenter: SharingServicePresenting {
    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge) {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
    }
}

// MARK: - Filename-safe timestamp helper

internal extension ISO8601DateFormatter {
    /// Short filename-safe UTC timestamp with a random disambiguator.
    /// Produces e.g. `20260409T144521-k7q2` (20 chars).
    ///
    /// Used by the `.bundle` destination path to disambiguate back-to-back
    /// extractions when the user leaves the name at the default value.
    ///
    /// The 4-char random base36 suffix is required because the timestamp
    /// alone is second-resolution: two back-to-back Create-Bundle clicks
    /// inside the same wall-clock second would otherwise produce identical
    /// suffixes and the second extraction would silently clobber the first
    /// via `ReadExtractionService.createBundle`'s removeItem + moveItem.
    static func shortStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date)
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let random = String((0..<4).map { _ in alphabet.randomElement()! })
        return "\(stamp)-\(random)"
    }
}

// MARK: - TaskBox

extension TaxonomyReadExtractionAction {

    /// Main-actor-isolated holder for the in-flight pre-flight estimate and
    /// main extraction task handles.
    ///
    /// Used by `TaxonomyReadExtractionAction.present` to hand both task handles
    /// to the dialog's Cancel closure so either the pre-flight work or the
    /// full extraction can be torn down when the user dismisses the dialog.
    ///
    /// Both handles are needed because the initial estimate and the main
    /// extraction run in separate detached tasks. Cancel must stop whichever
    /// task is active; otherwise extraction can continue in the background and
    /// produce an orphaned bundle via `handleSuccess`.
    ///
    /// **Lifetime**: the box is created in `present()` and captured by value
    /// (reference) by the dialog's `onCancel` closure and the `onPrimary`
    /// closure. When the sheet closes and the dialog view hierarchy releases
    /// its closures, the box is released with the closures — no explicit
    /// clear needed under ARC.
    @MainActor
    final class TaskBox {
        var estimateTask: Task<Void, Never>?
        var extractionTask: Task<Void, Never>?
    }
}
