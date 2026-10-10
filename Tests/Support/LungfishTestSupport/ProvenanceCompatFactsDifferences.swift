// ProvenanceCompatFactsDifferences.swift - One comparison helper for facts, so no lane hand-rolls its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A writer lane compares the facts of the bytes its new writer produces with the facts of the
// frozen case. Some facts legitimately differ, such as the host values a run records or the
// shape of the file after a conversion. Rather than let each lane keep its own list of allowed
// differences, `differences(from:ignoring:)` takes a set of named fields and the two documented
// sets below, and returns one line per remaining difference that names the field.

import Foundation

extension ProvenanceCompatFacts {
    /// A field, or one named part of a field, that a comparison may ignore.
    public enum Field: String, CaseIterable, Sendable {
        case decodedBy
        case strictAccepts
        case opsStats
        /// Only `opsStats.totalWallTimeSeconds`, which is derived from whole-second dates.
        case opsStatsTotalWallTimeSeconds
        case status
        case embeddedRunStatus
        case readStatus
        case workflowName
        case toolName
        case toolVersion
        case argv
        case durableReplayArgv
        case reproducibleCommand
        case exitStatus
        /// The run's `wallTimeSeconds`.
        case wallTimeSeconds
        case stderr
        case explicitOptions
        case defaultOptions
        case resolvedDefaultOptions
        case legacyRunParameters
        /// The whole `files` list.
        case files
        /// Only repeated entries of one file under one role. The files are then compared as a set
        /// on path, role, SHA-256 and size.
        case filesDuplicates
        case output
        case outputs
        case steps
        /// Only the wall time of each step, in `steps`, `legacyRunSteps` and `canonicalRunSteps`.
        case stepWallTimeSeconds
        case legacyRunSteps
        case canonicalRunSteps
        /// The top-level `recorded` map of values the bytes hold for host-filled keys.
        case recorded
    }

    /// What one run of a scenario decides for itself, so two runs of the same writer differ in it:
    /// the host values under `recorded` (app version, operating system, executable path, process id,
    /// creation date), the run's wall time, the wall time of each step and `opsStats.totalWallTimeSeconds`.
    public static let runSpecific: Set<Field> = [
        .recorded, .wallTimeSeconds, .stepWallTimeSeconds, .opsStatsTotalWallTimeSeconds,
    ]

    /// What a conversion from a bare run to a run-bearing envelope changes by design: which decoder
    /// accepts the bytes, whether the strict readers accept them, the embedded run's status key, and
    /// repeated `files` entries, which the envelope reader collapses to one per file and role.
    public static let shapeChange: Set<Field> = [
        .decodedBy, .strictAccepts, .embeddedRunStatus, .filesDuplicates,
    ]

    /// One line per way these facts differ from `expected`, each starting with the path of the field,
    /// such as `steps[1].durableReplayArgv: expected [...], found null`. An empty list means they agree.
    ///
    /// - Parameters:
    ///   - expected: The facts to compare against, usually the frozen case's.
    ///   - ignored: Fields to leave out of both sides. See ``runSpecific`` and ``shapeChange``.
    ///   - runWallTimeTolerance: When positive, the run's `wallTimeSeconds` values count as equal if
    ///     they differ by no more than this many seconds. A conversion from a bare run, whose dates are
    ///     whole seconds, to an envelope, which stores the exact wall time, needs one second.
    public func differences(
        from expected: ProvenanceCompatFacts,
        ignoring ignored: Set<Field> = [],
        runWallTimeTolerance: TimeInterval = 0
    ) -> [String] {
        guard var actualTree = Self.tree(of: self), var expectedTree = Self.tree(of: expected) else {
            return ["facts could not be encoded for comparison"]
        }
        if runWallTimeTolerance > 0,
           let actualWall = Self.number(actualTree["wallTimeSeconds"]),
           let expectedWall = Self.number(expectedTree["wallTimeSeconds"]),
           abs(actualWall - expectedWall) <= runWallTimeTolerance {
            actualTree["wallTimeSeconds"] = nil
            expectedTree["wallTimeSeconds"] = nil
        }
        for field in ignored {
            Self.prune(&actualTree, ignoring: field)
            Self.prune(&expectedTree, ignoring: field)
        }
        var lines: [String] = []
        Self.collectDifferences(.object(expectedTree), .object(actualTree), path: "", into: &lines)
        return lines
    }

    // MARK: Tree handling

    private static func tree(of facts: ProvenanceCompatFacts) -> [String: Value]? {
        guard let data = try? JSONEncoder().encode(facts),
              case .object(let members)? = try? JSONDecoder().decode(Value.self, from: data) else {
            return nil
        }
        return members
    }

    private static func number(_ value: Value?) -> Double? {
        switch value {
        case .integer(let number)?: return Double(number)
        case .number(let number)?: return number
        default: return nil
        }
    }

    private static func prune(_ tree: inout [String: Value], ignoring field: Field) {
        switch field {
        case .opsStatsTotalWallTimeSeconds:
            if case .object(var members)? = tree["opsStats"] {
                members["totalWallTimeSeconds"] = nil
                tree["opsStats"] = .object(members)
            }
        case .stepWallTimeSeconds:
            tree["steps"] = removingMember("wallTimeSeconds", fromElementsOf: tree["steps"])
            tree["legacyRunSteps"] = removingMember("wallTime", fromElementsOf: tree["legacyRunSteps"])
            tree["canonicalRunSteps"] = removingMember("wallTime", fromElementsOf: tree["canonicalRunSteps"])
        case .filesDuplicates:
            if case .array(let files)? = tree["files"] {
                tree["files"] = .array(identitySet(of: files))
            }
        default:
            tree[field.rawValue] = nil
        }
    }

    private static func removingMember(_ key: String, fromElementsOf value: Value?) -> Value? {
        guard case .array(let elements)? = value else { return value }
        return .array(elements.map { element in
            guard case .object(var members) = element else { return element }
            members[key] = nil
            return .object(members)
        })
    }

    /// The files as a sorted set of strings built from path, role, SHA-256 and size.
    private static func identitySet(of files: [Value]) -> [Value] {
        var identities = Set<String>()
        for case .object(let file) in files {
            func text(_ key: String) -> String {
                switch file[key] {
                case .string(let value)?: return value
                case .integer(let value)?: return String(value)
                default: return "-"
                }
            }
            identities.insert("path=\(text("path")) role=\(text("role")) sha256=\(text("sha256")) size=\(text("size"))")
        }
        return identities.sorted().map { .string($0) }
    }

    // MARK: Diff

    private static func collectDifferences(_ expected: Value?, _ actual: Value?, path: String, into lines: inout [String]) {
        switch (expected, actual) {
        case (nil, nil):
            return
        case (.object(let expectedMembers)?, .object(let actualMembers)?):
            for key in Set(expectedMembers.keys).union(actualMembers.keys).sorted() {
                collectDifferences(
                    expectedMembers[key],
                    actualMembers[key],
                    path: path.isEmpty ? key : "\(path).\(key)",
                    into: &lines
                )
            }
        case (.array(let expectedItems)?, .array(let actualItems)?):
            if expectedItems.count != actualItems.count {
                lines.append("\(path): expected \(expectedItems.count) element(s), found \(actualItems.count)")
            }
            for index in 0..<min(expectedItems.count, actualItems.count) {
                collectDifferences(expectedItems[index], actualItems[index], path: "\(path)[\(index)]", into: &lines)
            }
        default:
            if expected != actual {
                lines.append("\(path): expected \(describe(expected)), found \(describe(actual))")
            }
        }
    }

    private static func describe(_ value: Value?) -> String {
        guard let value else { return "<absent>" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<unprintable>" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 160 ? String(text.prefix(160)) + "..." : text
    }
}
