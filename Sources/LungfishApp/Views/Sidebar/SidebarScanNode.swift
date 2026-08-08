// SidebarScanNode.swift - Sendable value snapshot of a sidebar tree scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// F5/F7: the recursive project scan used to run entirely on the main actor,
// because it built `SidebarItem` (an `@MainActor` `NSObject`) and rendered
// AppKit badge images inline, mid-walk. That made "just move the scan off-main"
// impossible.
//
// This file breaks that entanglement. `SidebarScanNode` is an immutable,
// `Sendable` description of a sidebar row: what to show, not how to draw it. A
// badge is captured as *intent* (`BadgeDescriptor.text("NM")`) rather than a
// rendered `NSImage`, so the whole tree can be produced by `nonisolated` pure
// functions doing only filesystem and JSON work. The main actor then
// materializes the node tree into `SidebarItem`s, which is the only step that
// needs AppKit.

import Foundation

/// How a sidebar row's leading image should be produced.
///
/// Captures badge *intent* so the scan stays free of AppKit. The main-actor
/// materialization step turns each case into the actual image.
enum SidebarBadgeDescriptor: Sendable, Equatable {
    /// An SF Symbol name, rendered by the outline view's cell.
    case symbol(String)
    /// A short text pill (e.g. "NM", "NVD", "K2") rendered via `TextBadgeIcon`.
    case text(String)
}

/// An immutable, `Sendable` snapshot of one sidebar row and its subtree.
///
/// Produced off the main actor by the scan functions in
/// `SidebarViewController+Scan.swift`; converted to `SidebarItem` on the main
/// actor by `SidebarViewController.materialize(_:)`.
struct SidebarScanNode: Sendable, Equatable {
    var title: String
    var type: SidebarItemType
    var badge: SidebarBadgeDescriptor?
    var url: URL?
    var subtitle: String?
    var userInfo: [String: String]
    var children: [SidebarScanNode]

    init(
        title: String,
        type: SidebarItemType,
        badge: SidebarBadgeDescriptor? = nil,
        url: URL? = nil,
        subtitle: String? = nil,
        userInfo: [String: String] = [:],
        children: [SidebarScanNode] = []
    ) {
        self.title = title
        self.type = type
        self.badge = badge
        self.url = url
        self.subtitle = subtitle
        self.userInfo = userInfo
        self.children = children
    }
}
