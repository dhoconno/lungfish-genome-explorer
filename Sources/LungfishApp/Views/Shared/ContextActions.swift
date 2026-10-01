// ContextActions.swift - A SwiftUI context menu that VoiceOver and AX clients can reach
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// One entry of a ``SwiftUI/View/contextActions(_:)`` menu.
///
/// A command becomes both a context-menu button and an accessibility
/// action of the same title. A divider only shapes the menu. A header is an
/// informational line (disabled in the menu, ignored by accessibility), and a
/// submenu groups commands the way a nested context menu does, with its
/// enabled commands listed flat as accessibility actions.
struct ContextAction: Identifiable {
    indirect enum Kind {
        case command(role: ButtonRole?, isEnabled: Bool, perform: @MainActor () -> Void)
        case header
        case submenu([ContextAction])
        case divider
    }

    let id: String
    let title: String
    let kind: Kind
    /// The accessibility action name when the menu title would be ambiguous
    /// on its own, such as a primer's name inside an "Inspect Primer in
    /// Alignment" submenu. Defaults to ``title``.
    var accessibilityTitle: String?

    /// A command the menu and the accessibility actions both offer. Pass `id`
    /// when two commands can share a title, such as two primers with one name.
    /// A
    /// disabled command stays in the menu, greyed, and is left out of the
    /// accessibility actions.
    static func command(
        _ title: String,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        accessibilityTitle: String? = nil,
        id: String? = nil,
        _ perform: @escaping @MainActor () -> Void
    ) -> ContextAction {
        ContextAction(
            id: id ?? accessibilityTitle ?? title, title: title,
            kind: .command(role: role, isEnabled: isEnabled, perform: perform),
            accessibilityTitle: accessibilityTitle
        )
    }

    /// An informational line at the top of a menu, such as a summary of the
    /// item the menu belongs to.
    static func header(_ title: String) -> ContextAction {
        ContextAction(id: "header-\(title)", title: title, kind: .header)
    }

    /// A nested menu. Its enabled commands are also listed as accessibility
    /// actions, under their own titles.
    static func submenu(_ title: String, _ children: [ContextAction]) -> ContextAction {
        ContextAction(id: "submenu-\(title)", title: title, kind: .submenu(children))
    }

    /// A separator between groups of commands. Ignored by accessibility.
    static func divider(_ id: String = "divider") -> ContextAction {
        ContextAction(id: "divider-\(id)", title: "", kind: .divider)
    }

    var isCommand: Bool {
        if case .command = kind { return true }
        return false
    }

    /// The enabled commands of `actions`, which is what the accessibility
    /// actions list: dividers, headers and disabled commands dropped, submenu
    /// commands flattened in place, in menu order.
    static func commands(in actions: [ContextAction]) -> [ContextAction] {
        actions.flatMap { action -> [ContextAction] in
            switch action.kind {
            case let .command(_, isEnabled, _):
                return isEnabled ? [action] : []
            case let .submenu(children):
                return commands(in: children)
            case .header, .divider:
                return []
            }
        }
    }
}

extension View {
    /// Attaches a context menu whose commands are also published as
    /// accessibility actions, so a VoiceOver user or an AX-driven client
    /// reaches them without a secondary click.
    func contextActions(_ actions: [ContextAction]) -> some View {
        contextMenu {
            ContextActionMenuContent(actions: actions)
        }
        .accessibilityActions {
            ForEach(ContextAction.commands(in: actions)) { action in
                ContextActionButton(action: action, forAccessibility: true)
            }
        }
    }
}

/// Renders ``ContextAction``s as menu content: buttons, dividers, disabled
/// header lines and nested menus.
struct ContextActionMenuContent: View {
    let actions: [ContextAction]

    var body: some View {
        ForEach(actions) { action in
            ContextActionMenuEntry(action: action)
        }
    }
}

private struct ContextActionMenuEntry: View {
    let action: ContextAction

    var body: some View {
        switch action.kind {
        case .command:
            ContextActionButton(action: action)
        case .header:
            // A plain label, not a disabled button, so the line reads as
            // information rather than as a command that cannot run.
            Text(action.title)
        case let .submenu(children):
            Menu(action.title) {
                ContextActionMenuContent(actions: children)
            }
        case .divider:
            Divider()
        }
    }
}

private struct ContextActionButton: View {
    let action: ContextAction
    var forAccessibility = false

    var body: some View {
        if case let .command(role, isEnabled, perform) = action.kind {
            Button(forAccessibility ? (action.accessibilityTitle ?? action.title) : action.title, role: role) { perform() }
                .disabled(!isEnabled)
        }
    }
}
