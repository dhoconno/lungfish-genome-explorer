// SiteFactRules.swift - The bounds on a run's site facts, shared by the executor and the Mac's adopt (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The rules a `--site-fact KEY=VALUE` argument must keep (tally-r2 3.1). `lungfish-executor run` refuses an argument
/// that breaks one before any tool starts, and the Mac's adopt checks a run record's `siteFacts` against the same rules
/// (C4-02), so the two never disagree on a bound. A rule names the fact's position and never quotes its value.
package enum SiteFactRules {
    package static let maximumSiteFacts = 64
    package static let maximumSiteFactValueBytes = 1024

    /// The first fact that breaks a rule: its position from 1, and the rule's words after "Site fact <position> ".
    package struct Violation: Error, Equatable, Sendable {
        package var position: Int
        package var rule: String

        package init(position: Int, rule: String) {
            self.position = position
            self.rule = rule
        }

        /// "Site fact <position> <rule>".
        package var sentence: String { "Site fact \(position) \(rule)" }
    }

    /// The site facts in the order given, or the first rule an argument breaks. A fact is recorded and never
    /// interpreted, passed to a tool or used to find a file.
    package static func siteFacts(_ arguments: [String]) -> Result<[PlanKeyValue], Violation> {
        guard arguments.count <= maximumSiteFacts else { return .failure(overLimit) }
        var facts: [PlanKeyValue] = []
        var keys = Set<String>()
        for (offset, text) in arguments.enumerated() {
            let position = offset + 1
            guard let equals = text.firstIndex(of: "=") else {
                return .failure(Violation(position: position, rule: "is not KEY=VALUE."))
            }
            let fact = PlanKeyValue(key: String(text[..<equals]), value: String(text[text.index(after: equals)...]))
            if let rule = brokenRule(fact, keys: &keys) { return .failure(Violation(position: position, rule: rule)) }
            facts.append(fact)
        }
        return .success(facts)
    }

    /// The first rule a run record's `siteFacts` break, or nil when every fact keeps them.
    package static func violation(in facts: [PlanKeyValue]) -> Violation? {
        guard facts.count <= maximumSiteFacts else { return overLimit }
        var keys = Set<String>()
        for (offset, fact) in facts.enumerated() {
            if let rule = brokenRule(fact, keys: &keys) { return Violation(position: offset + 1, rule: rule) }
        }
        return nil
    }

    /// `[A-Za-z][A-Za-z0-9_]{0,63}`.
    package static func isSiteFactKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        func letter(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) }
        guard (1...64).contains(scalars.count), letter(scalars[0]) else { return false }
        return scalars.allSatisfy { letter($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    private static var overLimit: Violation {
        Violation(position: maximumSiteFacts + 1, rule: "is over the limit of \(maximumSiteFacts) site facts.")
    }

    /// The rule one fact breaks, in the order the executor has always checked them. `keys` holds the earlier keys.
    private static func brokenRule(_ fact: PlanKeyValue, keys: inout Set<String>) -> String? {
        guard isSiteFactKey(fact.key) else {
            return "has a key that is not a letter followed by at most 63 letters, digits or underscores."
        }
        guard fact.value.utf8.count <= maximumSiteFactValueBytes else {
            return "has a value over \(maximumSiteFactValueBytes) bytes."
        }
        guard !fact.value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return "has a value that holds a control character."
        }
        guard keys.insert(fact.key).inserted else { return "repeats the key of an earlier site fact." }
        return nil
    }
}
