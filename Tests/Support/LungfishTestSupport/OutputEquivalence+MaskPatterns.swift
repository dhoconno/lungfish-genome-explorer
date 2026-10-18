// OutputEquivalence+MaskPatterns.swift - The patterns and text helpers the masks share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The epoch keys, the UUID, run ID and ISO time patterns, the root spellings and the two replace helpers live here,
// moved unchanged out of OutputEquivalence+Masks.swift, which is over the size baseline and may not grow, so
// MaskPolicy could take a field there (Phase 2.12 lane 12.16, the manager's grant to its PrimalScheme3 case).

import Foundation

extension OutputEquivalence.Masks {
    static let epochKeys = [
        "createdAt", "endTime", "endedAt", "finishedAt", "recordedAt", "startTime", "startedAt", "timestamp",
    ]

    static var uuidPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f])"
    ) }

    static var runIDPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])aln_[0-9A-Fa-f]{8}(?![0-9A-Fa-f])"
    ) }

    static var isoTimestampPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: "(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}"
            + "(?:[T ][0-9]{2}[:\\-][0-9]{2}(?:[:\\-][0-9]{2}(?:[.,][0-9]+)?)?"
            + "(?:Z|[+\\-][0-9]{2}:?[0-9]{2})?)?(?![0-9])"
    ) }

    /// Each spelling of `root`, longest first, without a trailing slash.
    static func rootSpellings(_ root: URL) -> [String] {
        var forms: Set<String> = [
            root.path,
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().path,
        ]
        for form in forms {
            if form.hasPrefix("/private/") {
                forms.insert(String(form.dropFirst("/private".count)))
            } else if form.hasPrefix("/var/") || form.hasPrefix("/tmp/") {
                forms.insert("/private" + form)
            }
        }
        let plain = forms
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { $0.count > 1 }
        let escaped = plain.map { $0.replacingOccurrences(of: "/", with: "\\/") }
        return Array(Set(plain + escaped)).sorted { $0.count > $1.count }
    }

    static func replace(
        _ pattern: NSRegularExpression,
        in text: String,
        with token: (String) -> String
    ) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += token(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Replaces the value of each JSON key in `keys`, a string or a
    /// number, with the quoted `token`.
    static func replaceKeyValues(_ keys: [String], in text: String, token: String) -> String {
        let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = try! NSRegularExpression(
            pattern: "(\"(?:\(alternatives))\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+\\-]?[0-9]+)?)"
        )
        return pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "$1\"\(NSRegularExpression.escapedTemplate(for: token))\""
        )
    }
}
