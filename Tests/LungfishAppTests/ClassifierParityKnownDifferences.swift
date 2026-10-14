// ClassifierParityKnownDifferences.swift - Every declared difference of a classifier parity case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision T2 in docs/plans/2026-10-11-phase-2-7.md. A fixed fact that sides C and C' do not
// hold is declared here with its reason, the lane whose change removes it, and how many found
// differences it matches in each case. ClassifierCLIGUIParityReplayTests fails on a difference no
// entry declares and on an entry that matches more or fewer differences in a case than its count,
// so the list only shrinks, one difference at a time, and a new difference cannot hide under an old
// pattern. A lane that closes a difference lowers the count, or deletes the case or the entry, in
// the same commit. Sides A and B, the in-process route and its replay, went with the route in
// Phase 2.9 (E14, QA Q12), and with them the declared differences of A against B and A against C,
// which were most of this list. C against C', both ways, declares none.

import Foundation

/// Where a declared difference applies.
enum ClassifierParityScope: Hashable, Sendable, CustomStringConvertible {
    /// How the second side differs from the first, the reference side.
    case pair(ClassifierParitySide, ClassifierParitySide)
    /// A fixed fact one side does not hold.
    case side(ClassifierParitySide)

    var description: String {
        switch self {
        case .pair(let reference, let candidate): return "\(reference) against \(candidate)"
        case .side(let side): return "side \(side)"
        }
    }
}

/// One declared difference.
struct ClassifierParityKnownDifference: Sendable {
    /// The cases the entry applies to, each with the number of found differences it matches
    /// there.
    let counts: [ClassifierParityCase: Int]
    let scope: ClassifierParityScope
    /// The id of the difference, where `*` stands for any run of characters.
    let id: String
    let reason: String
    /// The lane whose change removes the difference, or the phase that retires the path.
    let closedBy: String

    func matches(_ difference: ClassifierParityDifference) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: id).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return difference.id.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ClassifierParityKnownDifferences {
    /// The fixed facts the command's runs do not hold, on side C and on side C'
    /// (ClassifierParityKnownDifferences+RouteC.swift).
    static let all: [ClassifierParityKnownDifference] = commandFacts

    /// One line per found difference that no entry declares, and per entry that matches another
    /// number of found differences than its count for `parityCase` in `scope`, listing the
    /// differences it matches.
    static func failures(
        found: [ClassifierParityDifference],
        parityCase: ClassifierParityCase,
        scope: ClassifierParityScope
    ) -> [String] {
        let declared = all.filter { $0.counts[parityCase] != nil && $0.scope == scope }
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
