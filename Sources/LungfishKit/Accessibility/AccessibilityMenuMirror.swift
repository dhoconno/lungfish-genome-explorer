// AccessibilityMenuMirror.swift - Mirrors a menu's items as AX custom actions on its owner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Mirrors a menu's items as accessibility custom actions on the control or
/// view that owns the menu.
///
/// A pull-down, a pop-up button or a table header column menu is reached by a
/// mouse click, which AX automation cannot make, and VoiceOver users have to
/// open the menu and walk it. With the mirror installed, the owner lists each
/// enabled, titled item as a custom action named after the item, and
/// performing the action does what choosing the item does. Items in a
/// one-level submenu are named "Submenu: Item" (see ``actionName(submenu:item:)``),
/// the one format every flattened submenu uses.
///
/// The mirror is a snapshot of the menu at install time, so an owner whose
/// menu is rebuilt (a delegate's `menuNeedsUpdate`) installs it again after
/// the rebuild.
@MainActor
public enum AccessibilityMenuMirror {
    /// Mirrors the button's menu on the button. A pull-down's first item is
    /// its title and is skipped. A pop-up's items select themselves and fire
    /// the button's action, exactly as choosing them would.
    public static func install(on popUp: NSPopUpButton) {
        guard let menu = popUp.menu else {
            popUp.setAccessibilityCustomActions(nil)
            return
        }
        let isPopUp = !popUp.pullsDown
        let actions = makeActions(for: menu, skippingFirst: popUp.pullsDown, selectsItems: isPopUp) { item, index in
            if isPopUp {
                // A pop-up's items carry the button cell's own internal
                // action; choosing one means selecting it and firing the
                // button's action.
                popUp.selectItem(at: index)
                if let action = popUp.action {
                    // Sent through the shared application, as `send(_:)`
                    // does. `NSControl.sendAction(_:to:)` goes through the
                    // `NSApp` global, which is nil until something creates
                    // the application, and then silently sends nothing.
                    NSApplication.shared.sendAction(action, to: popUp.target, from: popUp)
                }
            } else {
                send(item)
            }
        }
        apply(actions, to: popUp)
    }

    /// Mirrors `menu` on `owner`, for a view that pops the menu itself, such
    /// as a table header view or an action button.
    public static func install(_ menu: NSMenu, on owner: NSView) {
        let actions = actions(for: menu)
        apply(actions, to: owner)
    }

    /// Publishes `actions` on `owner`. A control that draws through a cell
    /// (`NSButton`, `NSPopUpButton`) is exposed to the AX server as its cell,
    /// which never reads the view's own custom actions, so they are set on
    /// the cell as well.
    public static func apply(_ actions: [NSAccessibilityCustomAction], to owner: NSView) {
        let value = actions.isEmpty ? nil : actions
        owner.setAccessibilityCustomActions(value)
        (owner as? NSControl)?.cell?.setAccessibilityCustomActions(value)
    }

    /// The custom actions that mirror `menu`, in menu order. Items without an
    /// action do nothing when chosen, so they are left out.
    public static func actions(for menu: NSMenu, skippingFirst: Bool = false) -> [NSAccessibilityCustomAction] {
        makeActions(for: menu, skippingFirst: skippingFirst, selectsItems: false) { item, _ in
            send(item)
        }
    }

    /// The accessibility action name of a submenu's item: "Submenu: Item",
    /// for example "Look Up on NCBI: NCBI Taxonomy". Every surface that
    /// flattens a submenu into actions names its items this way.
    public static func actionName(submenu: String, item: String) -> String {
        "\(submenu): \(item)"
    }

    /// Sends the item's action the way the menu would: to its target, or
    /// down the responder chain when it has none. Done directly rather than
    /// through `performActionForItem(at:)`, which flashes the item and
    /// delivers the action later.
    public static func send(_ item: NSMenuItem) {
        guard let action = item.action, item.isEnabled else { return }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    /// An item that does something when chosen, with the name its
    /// accessibility action carries.
    public struct FlattenedItem {
        public let name: String
        public let item: NSMenuItem
    }

    /// The items of `menu` that do something when chosen, with one submenu
    /// level flattened in place: enabled, titled, with an action. Separators,
    /// disabled items and items that only open a submenu are left out. An
    /// item that came from a submenu is named "Submenu: Item". This is the
    /// list a row's cell actions are built from when the row's context menu
    /// is the source of truth.
    public static func flattenedItems(of menu: NSMenu) -> [FlattenedItem] {
        if menu.autoenablesItems { menu.update() }
        var items: [FlattenedItem] = []
        for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty {
            if let submenu = item.submenu {
                if submenu.autoenablesItems { submenu.update() }
                for child in submenu.items
                where !child.isSeparatorItem && !child.title.isEmpty && child.isEnabled
                    && child.submenu == nil && child.action != nil {
                    items.append(FlattenedItem(name: actionName(submenu: item.title, item: child.title), item: child))
                }
                continue
            }
            guard item.isEnabled, item.action != nil else { continue }
            items.append(FlattenedItem(name: item.title, item: item))
        }
        return items
    }

    private static func makeActions(
        for menu: NSMenu,
        skippingFirst: Bool,
        selectsItems: Bool,
        perform: @escaping @MainActor (NSMenuItem, Int) -> Void
    ) -> [NSAccessibilityCustomAction] {
        // A pop-up's items carry no action of their own and would be
        // auto-disabled by update(); the button enables them itself.
        if menu.autoenablesItems && !selectsItems { menu.update() }
        var actions: [NSAccessibilityCustomAction] = []
        for (index, item) in menu.items.enumerated() {
            if skippingFirst && index == 0 { continue }
            guard !item.isSeparatorItem, !item.title.isEmpty, item.isEnabled else { continue }
            if let submenu = item.submenu {
                if submenu.autoenablesItems { submenu.update() }
                for child in submenu.items
                where !child.isSeparatorItem && !child.title.isEmpty && child.isEnabled
                    && child.submenu == nil && child.action != nil {
                    actions.append(AccessibilityCellActions.makeAction(name: actionName(submenu: item.title, item: child.title)) {
                        send(child)
                    })
                }
                continue
            }
            guard item.action != nil || selectsItems else { continue }
            actions.append(AccessibilityCellActions.makeAction(name: item.title) {
                perform(item, index)
            })
        }
        return actions
    }
}

/// A button that pops a menu on click and lists that menu's items as
/// accessibility custom actions, computed when an AX client asks.
///
/// The menu behind such a button is usually built fresh for every click,
/// from state that changes with the selection (an export menu whose scope
/// item counts the selected rows). Rather than reinstalling a snapshot on
/// every change, the button asks ``menuProvider`` for the current menu
/// whenever its actions are read, so the list is never stale.
///
/// An `NSButton` reaches the AX server as its cell, which never reads the
/// view's own custom actions, so the dynamic list is served by the button's
/// cell (``MenuMirroringButtonCell``) and only there, which keeps each
/// action listed once.
@MainActor
public final class MenuMirroringButton: NSButton {
    /// Builds the menu the button would pop right now. Nil publishes no
    /// actions.
    public var menuProvider: (() -> NSMenu?)?

    public override class var cellClass: AnyClass? {
        get { MenuMirroringButtonCell.self }
        set { _ = newValue }
    }

    /// The mirrored actions for the menu `menuProvider` builds right now.
    func mirroredActions() -> [NSAccessibilityCustomAction]? {
        guard let menu = menuProvider?() else { return nil }
        let actions = AccessibilityMenuMirror.actions(for: menu)
        return actions.isEmpty ? nil : actions
    }
}

/// The cell of a ``MenuMirroringButton``, which the AX server asks for the
/// button's custom actions.
@MainActor
public final class MenuMirroringButtonCell: NSButtonCell {
    public override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        (controlView as? MenuMirroringButton)?.mirroredActions() ?? super.accessibilityCustomActions()
    }
}
