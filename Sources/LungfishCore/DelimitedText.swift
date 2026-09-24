// DelimitedText.swift - Shared CSV/TSV field escaping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Shared CSV/TSV field escaping rules.
///
/// SIMP-10 (2026-09-23 best-practices audit): the codebase had about 15
/// separate escaper implementations with inconsistent rules - some TSV
/// escapers replaced tabs/LF/CR with a space, some forgot CR entirely, and
/// CSV quoting implementations varied in whether they handled embedded
/// carriage returns. `DelimitedText` is the one documented rule set new
/// call sites should use.
///
/// These rules intentionally match RFC 4180 for CSV (quote the field if it
/// contains the delimiter, a quote, or any line-break character; double
/// embedded quotes) and the common TSV convention of replacing tab and any
/// line-break character with a single space (TSV has no quoting mechanism,
/// so a literal tab or newline in a field would otherwise corrupt column
/// alignment).
public enum DelimitedText {
    /// Escapes `value` for inclusion as one CSV field.
    ///
    /// Quotes the field (doubling any embedded `"`) when it contains a
    /// comma, a double quote, or any line-break character (`\n` or `\r`).
    /// Otherwise returns `value` unchanged.
    public static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Escapes `value` for inclusion as one TSV field.
    ///
    /// TSV has no quoting mechanism, so a literal tab, `\n`, or `\r` inside
    /// `value` would otherwise misalign columns or rows. Each is replaced
    /// with a single space.
    public static func tsvField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Escapes `value` for a field delimited by an arbitrary single-character
    /// `separator`, following the CSV quoting rule generalized to that
    /// separator (used by exporters that support choosing "," or "\t" for
    /// the same code path).
    public static func delimitedField(_ value: String, separator: Character) -> String {
        guard value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
