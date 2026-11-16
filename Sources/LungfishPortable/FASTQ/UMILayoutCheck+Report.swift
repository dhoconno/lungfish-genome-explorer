// UMILayoutCheck+Report.swift - The verdict, the shares and the words of the UMI layout check, the step's `home` file
// (Phase 5.3 lane EX-UMI, BIO-UMI-SHARE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension UMILayoutCheck {
    package enum Verdict: String, Codable, Sendable {
        case passed
        case warned
        case failed
    }

    /// Why the check warned or failed, in the order the words give them.
    package enum ReasonCode: String, Codable, Sendable {
        case namesDiffer
        case shortMate
        case noPairRead
        case withinOneMismatchUnderBar
        case distinctUnderFailBar
        case exactUnderBar
        case distinctUnderWarnBar
    }

    package struct Reason: Codable, Equatable, Sendable {
        package var code: ReasonCode
        /// True for a failure, false for a warning.
        package var fails: Bool
        package var words: String
    }

    /// What a share divides by. Every share that gates divides by the pairs read (BIO-UMI-SHARE item 1), and the distinct
    /// UMIs among the exact-motif pairs are printed beside it and gate nothing (item 3).
    package enum Denominator: String, Codable, Sendable {
        case pairsRead
        case exact
    }

    package struct Share: Codable, Equatable, Sendable {
        package var id: String
        package var count: Int
        package var denominator: Denominator
        package var of: Int
        /// The share cut down to one decimal, so a share under a bar never reads as the bar (item 7).
        package var percent: String
    }

    /// The `home` file: the pairs requested and read, the choice, the counts, each share with its denominator named, each
    /// bar, the verdict, each reason and the words (BIO-UMI-SHARE item 10). The adopt and the per-sample report read it.
    package struct Report: Codable, Equatable, Sendable {
        package var schemaVersion = 1
        package var kit: String
        package var motif: String
        package var umiLength: Int
        package var umiRead: Int
        package var read1: String
        package var read2: String
        package var choice: Choice
        package var counts: Counts
        package var shares: [Share]
        package var bars: Bars
        package var verdict: Verdict
        package var reasons: [Reason]
        package var words: String

        package init(counts: Counts, arguments: Arguments) {
            kit = arguments.kit
            motif = arguments.motif
            umiLength = arguments.umiLength
            umiRead = arguments.umiRead
            read1 = arguments.read1
            read2 = arguments.read2
            choice = arguments.choice
            self.counts = counts
            bars = arguments.bars
            let pairs = counts.pairsRead
            shares = [
                Share(id: "namesEqual", count: counts.namesEqual, denominator: .pairsRead, of: pairs, percent: UMILayoutCheck.percent(counts.namesEqual, of: pairs)),
                Share(id: "withinOneMismatch", count: counts.withinOneMismatch, denominator: .pairsRead, of: pairs,
                      percent: UMILayoutCheck.percent(counts.withinOneMismatch, of: pairs)),
                Share(id: "exact", count: counts.exact, denominator: .pairsRead, of: pairs, percent: UMILayoutCheck.percent(counts.exact, of: pairs)),
                Share(id: "distinctUMIs", count: counts.distinctUMIs, denominator: .pairsRead, of: pairs,
                      percent: UMILayoutCheck.percent(counts.distinctUMIs, of: pairs)),
                Share(id: "distinctUMIsAmongExact", count: counts.distinctUMIs, denominator: .exact, of: counts.exact,
                      percent: UMILayoutCheck.percent(counts.distinctUMIs, of: counts.exact)),
            ]
            reasons = UMILayoutCheck.reasons(counts, arguments)
            let failures = reasons.filter(\.fails)
            if !failures.isEmpty {
                verdict = .failed
                words = failures.map(\.words).joined(separator: "\n")
            } else {
                verdict = reasons.isEmpty ? .passed : .warned
                words = ([UMILayoutCheck.passWords(counts, arguments)] + reasons.map(\.words)).joined(separator: "\n")
            }
        }
    }

    /// `count` of `total` cut down to one decimal, `0.0` of none.
    static func percent(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "0.0" }
        let tenths = count * 1000 / total
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// `n` with a comma between each group of three digits.
    package static func grouped(_ n: Int) -> String {
        var digits = String(n.magnitude)
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        return (n < 0 ? "-" : "") + ([digits] + groups).joined(separator: ",")
    }

    static func passWords(_ counts: Counts, _ arguments: Arguments) -> String {
        let pairs = counts.pairsRead
        return "UMI layout check passed: \(grouped(counts.withinOneMismatch)) of \(grouped(pairs)) pairs read "
            + "(\(percent(counts.withinOneMismatch, of: pairs))%) start within one mismatch of \(arguments.motif), "
            + "\(grouped(counts.exact)) (\(percent(counts.exact, of: pairs))%) exactly, and \(grouped(counts.distinctUMIs)) "
            + "(\(percent(counts.distinctUMIs, of: pairs))%) hold a distinct UMI."
    }
}
