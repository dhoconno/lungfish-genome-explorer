// VariantChromosomeLookupKey.swift - Loose chromosome label matching
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Canonicalizes chromosome labels for loose matching (e.g. `chr1` == `1`, `NC_000001.11` == `NC_000001`).
package func canonicalVariantChromosomeLookupKey(_ name: String) -> String {
    var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("chr") {
        value = String(value.dropFirst(3))
    }
    if let dot = value.firstIndex(of: ".") {
        value = String(value[..<dot])
    }
    return value
}
