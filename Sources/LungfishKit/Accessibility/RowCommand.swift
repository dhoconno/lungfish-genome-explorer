// RowCommand.swift - One command that acts on a selected row, from every surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A menu-bar key equivalent.
public struct RowCommandKeyEquivalent: Hashable, Sendable {
    public let key: String
    public let modifiers: NSEvent.ModifierFlags

    public init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

/// One command that acts on a selected row of some table or outline.
///
/// A row command is offered from several places that must always agree: the
/// row's context menu, the row's accessibility custom actions, and a
/// menu-bar item that sends ``menuSelector`` to the first responder. Each
/// surface's enum (``OperationRowAction``, the sidebar's commands, the result
/// tables' commands) adopts this protocol so the menu bar, the context menus
/// and the AX actions are all built from one list of titles and selectors.
public protocol RowCommand: Hashable {
    /// Menu title, as shown in the context menu and as the AX action name.
    var title: String { get }

    /// Title used in the menu bar, where the context title would be
    /// ambiguous without the row in front of the user. Defaults to ``title``.
    var menuBarTitle: String { get }

    /// Stable identifier suffix shared by the menu bar item and the AX action.
    var identifierSlug: String { get }

    /// Key equivalent for the menu bar item, if the command has one.
    var keyEquivalent: RowCommandKeyEquivalent? { get }

    /// The responder-chain selector the menu bar item sends.
    var menuSelector: Selector { get }
}

public extension RowCommand {
    var menuBarTitle: String { title }
    var keyEquivalent: RowCommandKeyEquivalent? { nil }
}

public extension RowCommand where Self: CaseIterable {
    /// The command whose menu-bar selector is `selector`, if any.
    static func command(for selector: Selector?) -> Self? {
        guard let selector else { return nil }
        return allCases.first { $0.menuSelector == selector }
    }
}

@MainActor
public extension RowCommand {
    /// A nil-target menu bar item for the command, so the first responder
    /// validates and performs it.
    func makeMenuBarItem(identifier: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: menuBarTitle,
            action: menuSelector,
            keyEquivalent: keyEquivalent?.key ?? ""
        )
        if let keyEquivalent {
            item.keyEquivalentModifierMask = keyEquivalent.modifiers
        }
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    /// A context menu item for the command, sending `action` to `target` with
    /// `representedObject` as the payload.
    func makeContextMenuItem(
        target: AnyObject?,
        action: Selector,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent?.key ?? "")
        if let keyEquivalent {
            item.keyEquivalentModifierMask = keyEquivalent.modifiers
        }
        item.target = target
        item.representedObject = representedObject
        return item
    }

    /// The command as an accessibility custom action named after its title.
    func makeAccessibilityAction(handler: @escaping @MainActor () -> Void) -> NSAccessibilityCustomAction {
        AccessibilityCellActions.makeAction(name: title, handler: handler)
    }
}
