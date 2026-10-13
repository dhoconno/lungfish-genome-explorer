// RouteParityHarness+Declared.swift - The differences a route parity class declares, and how a case fails
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30, as the classifier and TaxTriage lists do it since 2.7 T2. A family's parity
// class declares each difference of A against C with BIO's reason, the lane that removes it and the
// number of found differences it matches in each case. The count is exact, so a difference that
// goes, or one more under the same entry, fails the case until the count is lowered or the entry
// deleted in the same commit. A count only falls, which review holds (QC-2). Only A against C
// declares, and an entry for C against C' or for one side fails. A difference no entry declares fails,
// and so does a whole-file difference, which no entry may declare (panel G5).

import Foundation

/// Where a found difference sits.
public enum RouteParityScope: Hashable, Sendable, CustomStringConvertible {
    /// How side C differs from side A, the in-process route at the base.
    case aAgainstC
    /// How side C' differs from side C. It declares nothing (2.7 T2, panel C13).
    case cAgainstCPrime
    /// A fact one side does not hold.
    case side(RouteParitySide)

    /// Every scope, in the order a report lists them.
    public static let all: [RouteParityScope] = [.side(.a), .side(.c), .side(.cPrime), .aAgainstC, .cAgainstCPrime]

    public var description: String {
        switch self {
        case .aAgainstC: return "A against C"
        case .cAgainstCPrime: return "C against C'"
        case .side(let side): return "side \(side)"
        }
    }
}

/// One way two sides differ, or one fact a side does not hold.
public struct RouteParityDifference: Hashable, Sendable, CustomStringConvertible {
    /// A stable id. The class of the difference, then the masked path of its file, value or line.
    public let id: String
    /// What differs, with the values, for the failure message.
    public let detail: String
    /// Whether the difference stands for a whole file, a binary file or one with more differences
    /// than the explanation lists. No entry may declare it (panel G5).
    public let wholeFile: Bool

    public init(id: String, detail: String = "", wholeFile: Bool = false) {
        self.id = id
        self.detail = detail
        self.wholeFile = wholeFile
    }

    public var description: String { detail.isEmpty ? id : "\(id)\n        \(detail)" }
}

/// One difference a parity class declares.
public struct RouteParityDeclaredDifference<Case: Hashable & Sendable>: Sendable {
    /// The cases the entry applies to, each with the number of found differences it matches.
    public let counts: [Case: Int]
    public let scope: RouteParityScope
    /// The id of the difference, where `<ANY>` stands for any run of characters and `*` matches itself.
    public let id: String
    /// Why the routes differ here, in BIO's words.
    public let reason: String
    /// The lane whose change removes the difference, or the phase that retires the route.
    public let closedBy: String

    public init(
        _ counts: [Case: Int],
        _ id: String,
        scope: RouteParityScope = .aAgainstC,
        reason: String,
        closedBy: String
    ) {
        self.counts = counts
        self.scope = scope
        self.id = id
        self.reason = reason
        self.closedBy = closedBy
    }

    /// Whether `difference` has this entry's id, with `<ANY>` matching any run of characters.
    public func matches(_ difference: RouteParityDifference) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: id).replacingOccurrences(of: "<ANY>", with: ".*") + "$"
        return difference.id.range(of: pattern, options: .regularExpression) != nil
    }
}

extension RouteParityHarness {
    /// One line for each way `found` breaks the list `declared` gives `parityCase`. That is a
    /// found difference no entry declares, a whole-file difference and the entry that matches it,
    /// an entry that matches another number of found differences than its count, an entry that
    /// matches none, a count below one and any entry for C against C' or for one side.
    public static func failures<Case: Hashable & Sendable>(
        found: [RouteParityScope: [RouteParityDifference]],
        parityCase: Case,
        declared: [RouteParityDeclaredDifference<Case>]
    ) -> [String] {
        let entries = declared.filter { $0.counts[parityCase] != nil }
        var lines: [String] = []
        for entry in entries where entry.scope != .aAgainstC {
            lines.append("\(entry.scope) declares nothing, delete the entry (closed by \(entry.closedBy)): \(entry.id)")
        }
        for entry in entries where (entry.counts[parityCase] ?? 0) < 1 {
            lines.append("a count is at least 1, delete \(parityCase) from the entry instead (closed by \(entry.closedBy)): \(entry.id)")
        }
        for scope in RouteParityScope.all {
            let differences = found[scope] ?? []
            let scoped = scope == .aAgainstC ? entries.filter { $0.scope == scope } : []
            for difference in differences where difference.wholeFile || !scoped.contains(where: { $0.matches(difference) }) {
                lines.append("\(scope): not declared: \(difference)")
            }
            for entry in scoped {
                if differences.contains(where: { $0.wholeFile && entry.matches($0) }) {
                    lines.append(
                        "\(scope): a whole file cannot be declared, narrow the entry or show the file the same (closed by \(entry.closedBy)): \(entry.id)"
                    )
                    continue
                }
                let matched = differences.filter(entry.matches)
                let count = entry.counts[parityCase] ?? 0
                if matched.isEmpty {
                    lines.append("\(scope): declared but gone, delete \(parityCase) from the entry (closed by \(entry.closedBy)): \(entry.id)")
                } else if matched.count != count {
                    lines.append(
                        "\(scope): \(matched.count) differences match, \(count) declared for \(parityCase) (closed by \(entry.closedBy)): \(entry.id)"
                            + matched.map { "\n        \($0.id)" }.joined()
                    )
                }
            }
        }
        return lines
    }
}
