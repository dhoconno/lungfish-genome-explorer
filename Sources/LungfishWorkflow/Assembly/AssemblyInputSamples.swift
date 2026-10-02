// AssemblyInputSamples.swift - The samples an assembly names, as lungfish-cli assemble reads its inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The samples an assembly names. A `.lungfishfastq` bundle is one sample,
/// named by its own URL or by any file inside it, and a file outside every
/// bundle is a sample on its own. `lungfish-cli assemble` reads its inputs by
/// this rule (the files of one bundle given separately are that bundle,
/// once), so the app plans its assembly runs by it as well (R3).
public enum AssemblyInputSamples {
    /// The sample `inputURL` belongs to: its enclosing bundle, else the file.
    public static func sampleURL(for inputURL: URL) -> URL {
        SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) ?? inputURL.standardizedFileURL
    }

    /// The positions of `inputURLs` grouped by sample, each group in input
    /// order and the groups in the order their samples first appear.
    public static func groups(_ inputURLs: [URL]) -> [[Int]] {
        var keys: [String] = []
        var positions: [String: [Int]] = [:]
        for (index, inputURL) in inputURLs.enumerated() {
            let key = sampleURL(for: inputURL).path
            if positions[key] == nil { keys.append(key) }
            positions[key, default: []].append(index)
        }
        return keys.compactMap { positions[$0] }
    }
}
