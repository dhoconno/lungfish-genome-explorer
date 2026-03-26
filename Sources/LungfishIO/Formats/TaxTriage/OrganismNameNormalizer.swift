// OrganismNameNormalizer.swift - Shared organism name cleaning and normalization
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - OrganismNameNormalizer

/// Shared utilities for cleaning and normalizing organism names from
/// metagenomics pipeline output.
///
/// TaxTriage and EsViritu both produce organism names with decorative
/// characters (stars, bullets, degree signs) and occasional truncation
/// artifacts. This normalizer provides a single canonical implementation
/// used by parsers and view controllers alike.
public enum OrganismNameNormalizer {

    /// Removes decorative characters and repairs known truncation artifacts.
    ///
    /// Strips `★`, `°`, `●` (U+25CF) characters and trims whitespace.
    /// Also repairs the known Influenza leading-character truncation where
    /// "nfluenza" appears instead of "Influenza".
    ///
    /// - Parameter name: The raw organism name from pipeline output.
    /// - Returns: A cleaned organism name suitable for display.
    public static func clean(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "★", with: "")
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "\u{25CF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.lowercased().hasPrefix("nfluenza") {
            return "I" + cleaned
        }
        return cleaned
    }

    /// Produces a normalized key suitable for dictionary lookups and comparisons.
    ///
    /// Applies ``clean(_:)`` then lowercases, strips non-alphanumeric characters,
    /// and collapses whitespace to produce a canonical key string.
    ///
    /// - Parameter name: The raw organism name.
    /// - Returns: A normalized lowercase key (e.g., "escherichia coli").
    public static func normalizedKey(_ name: String) -> String {
        clean(name)
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }
}
