// ViewerViewSourceTestSupport.swift - shared source-introspection helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// AnnotationTableDrawerView.swift and SequenceViewerView.swift were mechanically
// split into focused extension files (<ClassName>+*.swift) to speed incremental
// compilation. Source-introspection tests that previously read only the single
// core file must now read the combined implementation (core file + all
// <ClassName>+*.swift) to find code that moved into an extension. These helpers
// return those concatenations.

import Foundation

/// Directory holding the Viewer source files.
private func viewerSourceDirectory() -> URL {
    // #filePath = .../Tests/LungfishAppTests/ViewerViewSourceTestSupport.swift
    // repo root = three levels up.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LungfishAppTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    return root.appendingPathComponent("Sources/LungfishApp/Views/Viewer", isDirectory: true)
}

/// Returns the concatenated source of `<coreFileName>` plus every sibling file
/// named `<classPrefix>+*.swift` in the Viewer directory, joined with newlines.
private func combinedViewerSource(coreFileName: String, extensionPrefix: String) -> String {
    let dir = viewerSourceDirectory()
    let fm = FileManager.default
    var urls: [URL] = [dir.appendingPathComponent(coreFileName)]

    if let entries = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) {
        let extensions = entries
            .filter { $0.lastPathComponent.hasPrefix(extensionPrefix) && $0.pathExtension == "swift" }
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

/// Returns the concatenated source of AnnotationTableDrawerView.swift plus every
/// AnnotationTableDrawerView+*.swift extension in the Viewer directory. Use this in
/// place of reading the single AnnotationTableDrawerView.swift file when asserting on
/// implementation patterns that may live in an extension file after the split.
func combinedAnnotationTableDrawerSource() -> String {
    combinedViewerSource(
        coreFileName: "AnnotationTableDrawerView.swift",
        extensionPrefix: "AnnotationTableDrawerView+"
    )
}

/// Returns the concatenated source of SequenceViewerView.swift plus every
/// SequenceViewerView+*.swift extension in the Viewer directory. Use this in place of
/// reading the single SequenceViewerView.swift file when asserting on implementation
/// patterns that may live in an extension file after the split.
func combinedSequenceViewerSource() -> String {
    combinedViewerSource(
        coreFileName: "SequenceViewerView.swift",
        extensionPrefix: "SequenceViewerView+"
    )
}
