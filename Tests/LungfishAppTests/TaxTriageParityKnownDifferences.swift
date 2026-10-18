// TaxTriageParityKnownDifferences.swift - Every declared difference between the sides of a TaxTriage parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1a, 2.7 T2. A declared difference names its reason, the lane or phase whose change
// removes it, and how many found differences it matches in each case. TaxTriageCLIGUIParityReplayTests
// fails on a difference no entry declares and on an entry that matches more or fewer differences in a
// case than its count, so the list only shrinks, one difference at a time, and a new difference cannot
// hide under an old pattern. Every entry of 2.9 to 2.11 described sides A and B, the legacy in-process
// route and its recorded command, so the 80 entries left with that route (2.12 K1). Sides C and C'
// declare nothing (2.7 T2), so the list is empty.

import Foundation

/// Where a declared difference applies.
enum TaxTriageParityScope: Hashable, Sendable, CustomStringConvertible {
    /// How the second side differs from the first, the reference side.
    case pair(TaxTriageParitySide, TaxTriageParitySide)
    /// A fixed fact one side does not hold.
    case side(TaxTriageParitySide)

    var description: String {
        switch self {
        case .pair(let reference, let candidate): return "\(reference) against \(candidate)"
        case .side(let side): return "side \(side)"
        }
    }
}

/// One declared difference.
struct TaxTriageParityKnownDifference: Sendable {
    /// The cases the entry applies to, each with the number of found differences it matches there.
    let counts: [TaxTriageParityCase: Int]
    let scope: TaxTriageParityScope
    /// The id of the difference, where `*` stands for any run of characters.
    let id: String
    let reason: String
    /// The lane whose change removes the difference, or the phase that retires the route.
    let closedBy: String

    func matches(_ difference: TaxTriageParityDifference) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: id).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return difference.id.range(of: pattern, options: .regularExpression) != nil
    }
}

enum TaxTriageParityKnownDifferences {
    static let all: [TaxTriageParityKnownDifference] = []

    /// One line per found difference that no entry declares, and per entry that matches another
    /// number of found differences than its count for `parityCase` in `scope`, listing the
    /// differences it matches. `declaredList` is the list read, `all` unless the real engine adds `liveFacts`.
    static func failures(
        found: [TaxTriageParityDifference],
        parityCase: TaxTriageParityCase,
        scope: TaxTriageParityScope,
        declaredList: [TaxTriageParityKnownDifference] = all
    ) -> [String] {
        let declared = declaredList.filter { $0.counts[parityCase] != nil && $0.scope == scope }
        var lines: [String] = []
        for difference in found where !declared.contains(where: { $0.matches(difference) }) {
            lines.append("not declared: \(difference)")
        }
        for entry in declared {
            let matched = found.filter(entry.matches)
            let count = entry.counts[parityCase] ?? 0
            if matched.isEmpty {
                lines.append("declared but gone, delete \(parityCase.rawValue) from the entry (closed by \(entry.closedBy)): \(entry.id)")
            } else if matched.count != count {
                lines.append(
                    "\(matched.count) differences match, \(count) declared for \(parityCase.rawValue) (closed by \(entry.closedBy)): \(entry.id)"
                        + matched.map { "\n        \($0.id)" }.joined()
                )
            }
        }
        return lines
    }
}
