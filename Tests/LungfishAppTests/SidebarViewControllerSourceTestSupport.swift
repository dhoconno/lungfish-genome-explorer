// SidebarViewControllerSourceTestSupport.swift - shared source-introspection helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// SidebarViewController.swift was mechanically split into focused files (the model
// types in SidebarItem.swift, the drop target view, and SidebarViewController+*.swift
// extension files) to speed incremental compilation. Source-introspection tests that
// previously read only SidebarViewController.swift must now read the combined
// implementation (core file + all the split files) to find code that moved into an
// extension. This helper returns that concatenation in the ORIGINAL source order so
// that tests which slice ranges spanning two methods (e.g. a method body bounded by
// the next method's header) remain valid.

import Foundation

/// Directory holding SidebarViewController.swift and its split files.
func sidebarViewControllerSourceDirectory() -> URL {
    // #filePath = .../Tests/LungfishAppTests/SidebarViewControllerSourceTestSupport.swift
    // repo root = three levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishAppTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return root.appendingPathComponent(
        "Sources/LungfishApp/Views/Sidebar",
        isDirectory: true
    )
}

/// File names (relative to the Sidebar directory) in the order they appeared in the
/// original monolithic SidebarViewController.swift. Keeping this order stable means
/// range-based source assertions that span method boundaries still resolve start < end.
private let sidebarViewControllerOrderedSourceFiles: [String] = [
    "SidebarViewController.swift",
    "SidebarViewController+AnalysisManifest.swift",
    "SidebarViewController+OutlineDataSource.swift",
    "SidebarViewController+OutlineDelegate.swift",
    "SidebarItem.swift",
    "SidebarViewController+MenuDelegate.swift",
    "SidebarDropTargetView.swift",
]

/// Returns the concatenated source of SidebarViewController.swift plus every split
/// file, joined with newlines in original source order. Use this in place of reading
/// the single SidebarViewController.swift file when asserting on SidebarViewController
/// implementation patterns.
func combinedSidebarViewControllerSource() -> String {
    let dir = sidebarViewControllerSourceDirectory()
    var pieces: [String] = []
    for name in sidebarViewControllerOrderedSourceFiles {
        let url = dir.appendingPathComponent(name)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            pieces.append(text)
        }
    }
    return pieces.joined(separator: "\n")
}
