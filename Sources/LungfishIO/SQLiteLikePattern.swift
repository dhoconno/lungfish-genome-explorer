// SQLiteLikePattern.swift - Helpers for literal SQLite LIKE patterns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

enum SQLiteLikePattern {
    static func contains(_ literal: String) -> String {
        "%\(escapedLiteral(literal))%"
    }

    static func prefix(_ literal: String) -> String {
        "\(escapedLiteral(literal))%"
    }

    static func suffix(_ literal: String) -> String {
        "%\(escapedLiteral(literal))"
    }

    static func escapedLiteral(_ literal: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(literal.count)
        for character in literal {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
