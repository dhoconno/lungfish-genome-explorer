// MainSplitViewControllerSourceTestSupport.swift - shared source-introspection helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// MainSplitViewController.swift was mechanically split into focused extension
// files (MainSplitViewController+*.swift) to speed incremental compilation.
// Source-introspection tests that previously read only MainSplitViewController.swift
// must now read the combined implementation (core file + all the +*.swift split
// files) to find code that moved into an extension. This helper returns that
// concatenation in the ORIGINAL source order so that tests which slice ranges
// spanning two methods (e.g. a method body bounded by the next method's header)
// remain valid.

import Foundation

/// Directory holding MainSplitViewController.swift and its split extensions.
public func mainSplitViewControllerSourceDirectory() -> URL {
    // #filePath = .../Tests/Support/LungfishTestSupport/MainSplitViewControllerSourceTestSupport.swift
    // repo root = four levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishTestSupport
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return root.appendingPathComponent(
        "Sources/LungfishApp/Views/MainWindow",
        isDirectory: true
    )
}

/// File names (relative to the MainWindow directory) in the order they appeared
/// in the original monolithic MainSplitViewController.swift. Keeping this order
/// stable means range-based source assertions that span method boundaries still
/// resolve start < end.
private let mainSplitViewControllerOrderedSourceFiles: [String] = [
    "MainSplitViewController.swift",
    "MainSplitViewController+MultiDocument.swift",
    "MainSplitViewController+FASTQImport.swift",
    "MainSplitViewController+ShellLayout.swift",
    "MainSplitViewController+Testing.swift",
    "MainSplitViewController+SidebarSelection.swift",
    "MainSplitViewController+ContentDisplay.swift",
    "MainSplitViewController+ClassifierDisplay.swift",
    "MainSplitViewController+GenomicsDisplay.swift",
]

public func mainSplitViewControllerSplitExtensionSourceFiles() -> [String] {
    mainSplitViewControllerOrderedSourceFiles.filter { $0.contains("+") }
}

/// Returns the concatenated source of MainSplitViewController.swift plus every
/// MainSplitViewController+*.swift split file, joined with newlines in original
/// source order. Use this in place of reading the single MainSplitViewController.swift
/// file when asserting on MainSplitViewController implementation patterns.
public func combinedMainSplitViewControllerSource() -> String {
    let dir = mainSplitViewControllerSourceDirectory()
    var pieces: [String] = []
    for name in mainSplitViewControllerOrderedSourceFiles {
        let url = dir.appendingPathComponent(name)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            pieces.append(text)
        }
    }
    return pieces.joined(separator: "\n")
}
