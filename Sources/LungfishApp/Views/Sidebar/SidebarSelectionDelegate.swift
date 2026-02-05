// SidebarSelectionDelegate.swift
// LungfishApp
//
// Protocol for handling sidebar selection changes using standard AppKit delegate pattern.
// This replaces NotificationCenter-based communication for more reliable, synchronous handling.

import Foundation

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
}

// MARK: - Default Implementations

public extension SidebarSelectionDelegate {
    /// Default implementation forwards to single-selection handler with first item.
    func sidebarDidSelectItems(_ items: [SidebarItem]) {
        sidebarDidSelectItem(items.first)
    }
}
