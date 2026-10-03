// ProvenanceName.swift - Normalizes a required name string with a fallback
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum ProvenanceName {
    static func required(_ value: String?, fallback: String = "unknown") -> String {
        let fallbackValue = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallback = fallbackValue.isEmpty ? "unknown" : fallbackValue
        guard let value else { return normalizedFallback }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? normalizedFallback : normalized
    }
}
