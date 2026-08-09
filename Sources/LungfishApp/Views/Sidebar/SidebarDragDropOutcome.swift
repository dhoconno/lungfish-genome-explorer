// SidebarDragDropOutcome.swift - Partial-failure summary for sidebar drag-drop move/copy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E4 (2026-08-08 repo review fix campaign, finding AS4): moveItems/
// copyItems previously only os_log'd per-item failures (missing URL,
// move-into-self-or-descendant, FileManager error) inside their loop and
// continued, with no NSAlert ever shown for a partial failure — the
// boolean acceptDrop return only controlled AppKit's drag-snapback
// animation, not any user-visible message. This type accumulates a
// per-item skip reason so the caller can present exactly what happened.

import Foundation

/// Why a single item was skipped during a sidebar move/copy.
enum SidebarDragDropSkipReason: Equatable {
    case missingURL
    case moveIntoSelfOrDescendant
    case fileSystemError(String)

    var reasonText: String {
        switch self {
        case .missingURL:
            return "missing file location"
        case .moveIntoSelfOrDescendant:
            return "cannot move into itself or a subfolder of itself"
        case .fileSystemError(let message):
            return message
        }
    }
}

enum SidebarDragDropKind {
    case move
    case copy

    var verb: String {
        switch self {
        case .move: return "moved"
        case .copy: return "copied"
        }
    }

    var gerund: String {
        switch self {
        case .move: return "Moving"
        case .copy: return "Copying"
        }
    }
}

/// Accumulates the outcome of a multi-item sidebar move/copy so partial
/// failures can be reported to the user instead of only logged.
struct SidebarDragDropOutcome {
    let kind: SidebarDragDropKind
    private(set) var succeededCount: Int = 0
    private(set) var skipped: [(title: String, reason: SidebarDragDropSkipReason)] = []

    init(kind: SidebarDragDropKind) {
        self.kind = kind
    }

    mutating func recordSuccess() {
        succeededCount += 1
    }

    mutating func recordSkip(title: String, reason: SidebarDragDropSkipReason) {
        skipped.append((title, reason))
    }

    var hasPartialFailure: Bool { !skipped.isEmpty }

    var alertTitle: String {
        switch kind {
        case .move: return "Some Items Could Not Be Moved"
        case .copy: return "Some Items Could Not Be Copied"
        }
    }

    func alertInformativeText(totalSelected: Int) -> String {
        let details = skipped.map { "\($0.title) (\($0.reason.reasonText))" }.joined(separator: "\n")
        return "\(succeededCount) of \(totalSelected) selected item(s) were \(kind.verb). The rest were skipped:\n\(details)"
    }
}
