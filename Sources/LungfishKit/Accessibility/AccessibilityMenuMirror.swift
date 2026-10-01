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
/// one-level submenu are named "Submenu > Item".
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
                    popUp.sendAction(action, to: popUp.target)
                }
            } else {
                send(item)
            }
        }
        popUp.setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
    }

    /// Mirrors `menu` on `owner`, for a view that pops the menu itself, such
    /// as a table header view or an action button.
    public static func install(_ menu: NSMenu, on owner: NSView) {
        let actions = actions(for: menu)
        owner.setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
    }

    /// The custom actions that mirror `menu`, in menu order. Items without an
    /// action do nothing when chosen, so they are left out.
    public static func actions(for menu: NSMenu, skippingFirst: Bool = false) -> [NSAccessibilityCustomAction] {
        makeActions(for: menu, skippingFirst: skippingFirst, selectsItems: false) { item, _ in
            send(item)
        }
    }

    /// Sends the item's action the way the menu would: to its target, or
    /// down the responder chain when it has none. Done directly rather than
    /// through `performActionForItem(at:)`, which flashes the item and
    /// delivers the action later.
    private static func send(_ item: NSMenuItem) {
        guard let action = item.action, item.isEnabled else { return }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
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
                    actions.append(AccessibilityCellActions.makeAction(name: "\(item.title) > \(child.title)") {
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
