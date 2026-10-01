// ContextActions.swift - A SwiftUI context menu that VoiceOver and AX clients can reach
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// One entry of a ``SwiftUI/View/contextActions(_:)`` menu.
///
/// A command becomes both a context-menu button and an accessibility
/// action of the same title. A divider only shapes the menu.
struct ContextAction: Identifiable {
    enum Kind {
        case command(role: ButtonRole?, perform: @MainActor () -> Void)
        case divider
    }

    let id: String
    let title: String
    let kind: Kind

    /// A command the menu and the accessibility actions both offer.
    static func command(
        _ title: String,
        role: ButtonRole? = nil,
        _ perform: @escaping @MainActor () -> Void
    ) -> ContextAction {
        ContextAction(id: title, title: title, kind: .command(role: role, perform: perform))
    }

    /// A separator between groups of commands. Ignored by accessibility.
    static func divider(_ id: String = "divider") -> ContextAction {
        ContextAction(id: "divider-\(id)", title: "", kind: .divider)
    }

    var isCommand: Bool {
        if case .command = kind { return true }
        return false
    }

    /// The commands of `actions`, which is what the accessibility actions
    /// list: dividers dropped, in menu order.
    static func commands(in actions: [ContextAction]) -> [ContextAction] {
        actions.filter(\.isCommand)
    }
}

extension View {
    /// Attaches a context menu whose commands are also published as
    /// accessibility actions, so a VoiceOver user or an AX-driven client
    /// reaches them without a secondary click.
    func contextActions(_ actions: [ContextAction]) -> some View {
        contextMenu {
            ForEach(actions) { action in
                ContextActionMenuEntry(action: action)
            }
        }
        .accessibilityActions {
            ForEach(ContextAction.commands(in: actions)) { action in
                ContextActionButton(action: action)
            }
        }
    }
}

private struct ContextActionMenuEntry: View {
    let action: ContextAction

    var body: some View {
        switch action.kind {
        case .command:
            ContextActionButton(action: action)
        case .divider:
            Divider()
        }
    }
}

private struct ContextActionButton: View {
    let action: ContextAction

    var body: some View {
        if case let .command(role, perform) = action.kind {
            Button(action.title, role: role) { perform() }
        }
    }
}
