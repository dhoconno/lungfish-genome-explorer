// AppDelegateSourceTestSupport.swift - shared source-introspection helper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// AppDelegate.swift was mechanically split into focused extension files
// (AppDelegate+*.swift) to speed incremental compilation. Source-introspection
// tests that previously read only AppDelegate.swift must now read the combined
// implementation (core file + all AppDelegate+*.swift) to find code that moved
// into an extension. This helper returns that concatenation.

import Foundation

/// Directory holding AppDelegate.swift and its AppDelegate+*.swift extensions.
public func appDelegateSourceDirectory() -> URL {
    // #filePath = .../Tests/Support/LungfishTestSupport/AppDelegateSourceTestSupport.swift
    // repo root = four levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishTestSupport
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return root.appendingPathComponent("Sources/LungfishApp/App", isDirectory: true)
}

/// Returns the concatenated source of AppDelegate.swift plus every AppDelegate+*.swift
/// in the App directory, joined with newlines. Use this in place of reading the single
/// AppDelegate.swift file when asserting on AppDelegate implementation patterns.
public func combinedAppDelegateSource() -> String {
    let dir = appDelegateSourceDirectory()
    let fm = FileManager.default
    var urls: [URL] = [dir.appendingPathComponent("AppDelegate.swift")]

    if let entries = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) {
        let extensions = entries
            .filter { $0.lastPathComponent.hasPrefix("AppDelegate+") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        urls.append(contentsOf: extensions)
    }

    var pieces: [String] = []
    for url in urls {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            pieces.append(text)
        }
    }
    return pieces.joined(separator: "\n")
}
