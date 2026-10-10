// ProvenanceStderr.swift - The one rule for how much of a tool's stderr a provenance record keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceStderr {
    /// Tools print their banner first and their errors, versions and summaries
    /// last, so a stderr over `maxLength` keeps its first `headLength` and its last
    /// `tailLength` characters. Anything at or under `maxLength` is kept whole.
    public static let headLength = 2_048
    public static let tailLength = 8_192
    public static let maxLength = headLength + tailLength
    /// Joins the head and the tail. It carries no count, so two cuts of
    /// different lengths read the same.
    public static let truncationMarker = "\n... [truncated] ...\n"

    /// The stderr a record keeps, and nil for a nil stderr. A value of at most
    /// `maxLength` characters is kept whole, and a longer one keeps its first
    /// `headLength` and its last `tailLength` characters around `truncationMarker`.
    public static func truncated(_ stderr: String?) -> String? {
        guard let stderr else {
            return nil
        }
        guard stderr.count > maxLength else {
            return stderr
        }
        return String(stderr.prefix(headLength)) + truncationMarker + String(stderr.suffix(tailLength))
    }

    /// ``truncated(_:)`` of a stderr that holds more than whitespace, and nil
    /// for a blank one.
    public static func normalized(_ stderr: String?) -> String? {
        guard let stderr = truncated(stderr) else {
            return nil
        }
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : stderr
    }
}
