// AppDelegate+ReferenceBundleResolution.swift - Which reference bundle the menu actions act on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension AppDelegate {
    /// Order of preference: what the viewer actually displays (either display
    /// route, then a mapping result's reference copy), then a single sidebar
    /// candidate. Several sidebar candidates are ambiguous and resolve to `nil`.
    static func resolveReferenceBundleURL(
        currentReferenceBundleURL: URL?,
        currentBundleURL: URL?,
        referenceViewportRenderedBundleURL: URL?,
        mappingResultRenderedBundleURL: URL?,
        selectedBundleURLs: [URL] = []
    ) -> URL? {
        let displayed = currentReferenceBundleURL
            ?? currentBundleURL
            ?? referenceViewportRenderedBundleURL
            ?? mappingResultRenderedBundleURL
        if let displayed, displayed.pathExtension.lowercased() == "lungfishref" {
            return displayed
        }
        var unique: [URL] = []
        for url in selectedBundleURLs.map(\.standardizedFileURL) where !unique.contains(url) {
            unique.append(url)
        }
        return unique.count == 1 ? unique[0] : nil
    }
}
