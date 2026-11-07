// SidebarSelectionDelegate.swift
// LungfishApp
//
// Protocol for handling sidebar selection changes using standard AppKit delegate pattern.
// This replaces NotificationCenter-based communication for more reliable, synchronous handling.

import Foundation

public enum SidebarSelectionTransition: Equatable, Sendable {
    case selection
    case refresh
}

/// Protocol for handling sidebar selection changes.
///
/// Implement this protocol to receive direct callbacks when the user
/// selects items in the sidebar. This follows the standard AppKit delegate
/// pattern (like NSOutlineViewDelegate, NSTableViewDelegate) rather than
/// relying on NotificationCenter, which avoids Swift concurrency issues
/// when Tasks don't execute from notification handlers.
///
/// ## Usage
///
/// ```swift
/// class MyController: NSViewController, SidebarSelectionDelegate {
///     override func viewDidLoad() {
///         super.viewDidLoad()
///         sidebarController.selectionDelegate = self
///     }
///
///     func sidebarDidSelectItem(_ item: SidebarItem?) {
///         guard let item = item else {
///             clearViewer()
///             return
///         }
///         displayContent(for: item)
///     }
/// }
/// ```
@MainActor
public protocol SidebarSelectionDelegate: AnyObject {
    /// Gives the content owner an opportunity to resolve an in-memory edit
    /// before the sidebar commits selection UI, viewport callbacks, or
    /// selection notifications. Returning `true` means the delegate retained
    /// `commit` and will invoke it only after the transition is approved.
    func sidebarShouldDeferSelectionTransition(
        _ transition: SidebarSelectionTransition,
        commit: @escaping @MainActor () -> Void
    ) -> Bool

    /// Asks whether the sidebar may take a selection of `items`. `explicit` is true when a person asked for it
    /// without the outline having the focus (a context menu, the Inspector's source link, the Operations panel's
    /// Results button, the select after an import or a run, an accessibility select). A refused selection goes back
    /// to the committed rows and posts no notice, so the sidebar, the Inspector and the viewer all keep naming the
    /// content on screen.
    func sidebarShouldAcceptSelection(_ items: [SidebarItem], explicit: Bool) -> Bool

    /// Called when the sidebar selection changes to a single item.
    ///
    /// This method is called synchronously from `outlineViewSelectionDidChange`,
    /// so you can safely perform UI updates without needing async/await.
    ///
    /// - Parameter item: The selected sidebar item, or nil if selection was cleared
    func sidebarDidSelectItem(_ item: SidebarItem?)

    /// Called when the sidebar selection changes to multiple items.
    ///
    /// This method is called synchronously from `outlineViewSelectionDidChange`,
    /// so you can safely perform UI updates without needing async/await.
    ///
    /// - Parameter items: Array of selected sidebar items (may be empty)
    func sidebarDidSelectItems(_ items: [SidebarItem])

    /// Called when filesystem refresh keeps the same sidebar selection but the selected
    /// item may have new on-disk content.
    ///
    /// - Parameter items: Array of selected sidebar items that are still selected after refresh.
    func sidebarDidRefreshSelectedItems(_ items: [SidebarItem])
}

// MARK: - Default Implementations

public extension SidebarSelectionDelegate {
    func sidebarShouldDeferSelectionTransition(
        _ transition: SidebarSelectionTransition,
        commit: @escaping @MainActor () -> Void
    ) -> Bool {
        _ = transition
        _ = commit
        return false
    }

    func sidebarShouldAcceptSelection(_ items: [SidebarItem], explicit: Bool) -> Bool {
        _ = items
        _ = explicit
        return true
    }

    /// Default implementation forwards to single-selection handler with first item.
    func sidebarDidSelectItems(_ items: [SidebarItem]) {
        sidebarDidSelectItem(items.first)
    }

    func sidebarDidRefreshSelectedItems(_ items: [SidebarItem]) {}
}
