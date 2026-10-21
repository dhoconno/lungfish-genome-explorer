// CallerIdentityPaths.swift - Where a provenance record names its caller, which differs by design between routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27, R2 of BIO-Q-A2 and ruling MD62. A record names the tool that made it. The app's route
// names the app (`Lungfish Genome Explorer`, kind `gui`) and a leaf's route names `lungfish-cli` (kind `cli`), so
// the two routes differ at a fixed set of value paths of a record and at no other path. This one list is the
// declaration of those paths. `RouteParityHarness` reads it to explain a difference as `identity:`, which one
// entry (`RouteParityHarness.appIdentityDifference`) declares with an exact count, and the leaf tests that
// compare a record with the app's read it for their mask, so the mask and the declaration cannot drift apart.

import Foundation

public enum CallerIdentityPaths {
    /// The value paths that name the caller, with the index of `entries` and `steps` written as `[]`. The first
    /// word of an argv is the tool, so `argv[0]` is an identity path.
    public static let valuePaths: Set<String> = [
        "toolName", "tool.name", "tool.kind", "runtime.app", "argv[0]",
        "entries[].toolName", "entries[].runtime.app", "entries[].argv[0]",
        "steps[].toolName", "steps[].argv[0]",
    ]

    /// The value paths of a rendered command line. Such a path is an identity path only when the two values
    /// differ in their first word and agree after it.
    public static let commandPaths: Set<String> = ["reproducibleCommand", "steps[].reproducibleCommand"]

    /// `path` with the index of a leading `entries[n]` or `steps[n]` written as `[]`.
    public static func erasingIndex(_ path: String) -> String {
        path.replacingOccurrences(of: #"^(entries|steps)\[[0-9]+\]\."#, with: "$1[].", options: .regularExpression)
    }

    /// Whether the value at `path` names the caller, whichever route wrote the record.
    public static func isIdentityPath(_ path: String) -> Bool {
        valuePaths.contains(erasingIndex(path))
    }

    /// Whether the two values at `path` differ only as the caller's name does. Both sides hold a value, since a
    /// value that one side lacks is a structural difference, and a command line differs in its first word alone.
    /// A value is the JSON text of a scalar, as `RouteParityHarness.jsonValues` gives it.
    public static func isIdentityDifference(path: String, _ valueA: String?, _ valueB: String?) -> Bool {
        guard let valueA, let valueB, valueA != valueB else { return false }
        if isIdentityPath(path) { return true }
        guard commandPaths.contains(erasingIndex(path)) else { return false }
        let (firstA, restA) = split(valueA)
        let (firstB, restB) = split(valueB)
        return firstA != firstB && restA == restB
    }

    /// A copy of `value` without the dictionary entries whose scalar sits at an identity path, where `path` is
    /// the path of `value` in its file, such as `entries[0]` for a log entry.
    public static func removingIdentity(from value: Any, at path: String = "") -> Any {
        if let object = value as? [String: Any] {
            var kept: [String: Any] = [:]
            for (key, item) in object {
                let itemPath = path.isEmpty ? key : "\(path).\(key)"
                let isContainer = item is [String: Any] || item is [Any]
                if !isContainer, isIdentityPath(itemPath) { continue }
                kept[key] = removingIdentity(from: item, at: itemPath)
            }
            return kept
        }
        if let array = value as? [Any] {
            return array.enumerated().map { removingIdentity(from: $0.element, at: "\(path)[\($0.offset)]") }
        }
        return value
    }

    /// A dump of `path = value` lines without the lines at an identity path.
    public static func removingIdentityLines(from dump: String) -> String {
        dump.components(separatedBy: "\n").filter { line in
            guard let separator = line.range(of: " = ") else { return true }
            return !isIdentityPath(String(line[..<separator.lowerBound]))
        }.joined(separator: "\n")
    }

    /// The first word of a command line and the text after it. The JSON text of a string starts with a quote.
    private static func split(_ command: String) -> (first: Substring, rest: Substring) {
        let text = command.hasPrefix("\"") ? command.dropFirst() : Substring(command)
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (text[..<space], text[space...])
    }
}
