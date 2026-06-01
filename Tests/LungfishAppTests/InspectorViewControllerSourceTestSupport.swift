// InspectorViewControllerSourceTestSupport.swift - shared source-introspection helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// InspectorViewController.swift was mechanically split into focused files
// (InspectorViewController+*.swift, plus InspectorViewModel.swift, InspectorView.swift
// and InspectorSupportingTypes.swift) to speed incremental compilation.
// Source-introspection tests that previously read only InspectorViewController.swift
// must now read the combined implementation to find code that moved into another
// file. This helper returns that concatenation in the ORIGINAL source order so that
// tests slicing ranges that span method boundaries still resolve start < end.

import Foundation

/// Directory holding InspectorViewController.swift and its split files.
func inspectorViewControllerSourceDirectory() -> URL {
    // #filePath = .../Tests/LungfishAppTests/InspectorViewControllerSourceTestSupport.swift
    // repo root = three levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishAppTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return root.appendingPathComponent(
        "Sources/LungfishApp/Views/Inspector",
        isDirectory: true
    )
}

/// File names (relative to the Inspector directory) in the order they appeared in
/// the original monolithic InspectorViewController.swift, keeping range-based source
/// assertions that span declaration boundaries valid (start < end).
private let inspectorViewControllerOrderedSourceFiles: [String] = [
    "InspectorViewController.swift",
    "InspectorSupportingTypes.swift",
    "InspectorViewController+Notifications.swift",
    "InspectorViewController+Editing.swift",
    "InspectorViewController+PublicAPI.swift",
    "InspectorViewController+MetadataImport.swift",
    "InspectorViewController+VariantWorkflow.swift",
    "InspectorViewController+TrimDuplicateWorkflows.swift",
    "InspectorViewModel.swift",
    "InspectorView.swift",
]

/// Returns the concatenated source of InspectorViewController.swift plus every
/// InspectorViewController+*.swift and the InspectorViewModel/InspectorView/
/// InspectorSupportingTypes files, joined with newlines in original source order.
/// Use this in place of reading the single InspectorViewController.swift file when
/// asserting on InspectorViewController/InspectorView implementation patterns.
func combinedInspectorViewControllerSource() -> String {
    let dir = inspectorViewControllerSourceDirectory()
    var pieces: [String] = []
    for name in inspectorViewControllerOrderedSourceFiles {
        let url = dir.appendingPathComponent(name)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            pieces.append(text)
        }
    }
    return pieces.joined(separator: "\n")
}
