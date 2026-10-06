// FileNameBudget.swift - Keeps generated file and folder names inside the filesystem limit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Bounds generated file and folder names. macOS allows at most 255 bytes per
/// path component, and tip labels or user-entered names can exceed that.
public enum FileNameBudget {
    /// The most bytes macOS allows in one file or folder name.
    public static let maxComponentBytes = 255

    /// Returns `stem` cut so that the stem, the dot and extension, and a
    /// reserved suffix (for example "-99") fit in `maxComponentBytes`, which
    /// defaults to 200 to leave room below the 255-byte limit.
    ///
    /// A stem that already fits is returned unchanged. Otherwise whole
    /// Characters are dropped from the end, so a Character is never split,
    /// and the cut end is trimmed of "-", "_" and ".". An empty result
    /// becomes "untitled".
    public static func boundedStem(
        _ stem: String,
        pathExtension: String,
        reservedSuffixBytes: Int = 8,
        maxComponentBytes: Int = 200
    ) -> String {
        let extensionBytes = pathExtension.isEmpty ? 0 : 1 + pathExtension.utf8.count
        let budget = maxComponentBytes - extensionBytes - reservedSuffixBytes
        var result = Substring(stem)
        var bytes = result.utf8.count
        guard bytes > budget else { return stem.isEmpty ? "untitled" : stem }
        while bytes > budget, let last = result.last {
            bytes -= String(last).utf8.count
            result = result.dropLast()
        }
        while let last = result.last, "-_.".contains(last) { result = result.dropLast() }
        return result.isEmpty ? "untitled" : String(result)
    }
}
