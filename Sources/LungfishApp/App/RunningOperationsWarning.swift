// RunningOperationsWarning.swift - Text of the quit/close-with-running-operations sheets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import Foundation
import LungfishKit

/// Wording shared by the quit and window-close warnings.
///
/// Partial output of a cancelled run stays hidden from the sidebar. The next
/// time the project opens, the Operations Panel lists it as an Interrupted
/// row (size on disk, Remove…), so the text points there.
@MainActor
enum RunningOperationsWarning {
    enum Kind {
        case quit
        case closeWindow
    }

    static func messageText(kind: Kind, count: Int) -> String {
        let operations = count == 1 ? "1 Operation" : "\(count) Operations"
        switch kind {
        case .quit: return "Quit with \(operations) Running?"
        case .closeWindow: return "Close Window with \(operations) Running?"
        }
    }

    static func informativeText(kind: Kind, operations: [OperationCenter.Item]) -> String {
        let count = operations.count
        let plural = count == 1 ? "" : "s"
        let listedTitles = operations.prefix(6).map { "• \($0.title)" }.joined(separator: "\n")
        let overflowNote = count > 6 ? "\n… and \(count - 6) more" : ""
        let lead: String
        switch kind {
        case .quit:
            lead = "Quitting now will cancel the following operation\(plural)."
        case .closeWindow:
            lead = "Closing this window now will cancel the following operation\(plural) for this project."
        }
        return lead
            + " Any partial output stays out of the sidebar. The next time you open the project, "
            + "the Operations Panel lists it as Interrupted, with its size on disk and a Remove button.\n\n"
            + listedTitles + overflowNote
    }
}

/// Keeps a presented quit/close warning in step with ``OperationCenter``.
///
/// The sheet can stay open for a long time. A run that finishes meanwhile
/// drops off its list, and once nothing is running the sheet says so and
/// its destructive button becomes a plain Quit or Close, because nothing
/// will be cancelled any more. The caller reads ``operations`` again after
/// the sheet ends and acts on that, never on the list it opened with.
@MainActor
final class LiveRunningOperationsAlert {
    let alert: NSAlert
    private let kind: RunningOperationsWarning.Kind
    private let source: () -> [OperationCenter.Item]
    private var subscription: AnyCancellable?

    /// The operations still running, as last shown.
    private(set) var operations: [OperationCenter.Item] = []

    init(
        alert: NSAlert,
        kind: RunningOperationsWarning.Kind,
        center: OperationCenter = .shared,
        operations: @escaping () -> [OperationCenter.Item]
    ) {
        self.alert = alert
        self.kind = kind
        self.source = operations
        refresh()
        subscription = center.changes.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Stops following the operation center (call when the sheet ends).
    func stop() {
        subscription = nil
    }

    func refresh() {
        let current = source()
        guard current.map(\.id) != operations.map(\.id) || alert.informativeText.isEmpty else { return }
        operations = current
        let confirmButton = alert.buttons.first
        if current.isEmpty {
            switch kind {
            case .quit:
                alert.messageText = "All Operations Have Finished"
                alert.informativeText = "Nothing is running any more, so quitting cancels nothing."
                confirmButton?.title = "Quit"
            case .closeWindow:
                alert.messageText = "All Operations Have Finished"
                alert.informativeText = "Nothing is running for this project any more, so closing cancels nothing."
                confirmButton?.title = "Close"
            }
            confirmButton?.hasDestructiveAction = false
        } else {
            alert.messageText = RunningOperationsWarning.messageText(kind: kind, count: current.count)
            alert.informativeText = RunningOperationsWarning.informativeText(kind: kind, operations: current)
            switch kind {
            case .quit: confirmButton?.title = "Cancel Operations and Quit"
            case .closeWindow: confirmButton?.title = "Cancel Operations and Close"
            }
            confirmButton?.hasDestructiveAction = true
        }
        alert.layout()
    }
}
