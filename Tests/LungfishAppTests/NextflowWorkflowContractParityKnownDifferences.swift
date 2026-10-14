// NextflowWorkflowContractParityKnownDifferences.swift - Every declared difference between today's Viral Recon route and the contract
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q33 M2, plan N1 and N6. NextflowWorkflowContractParityReplayTests compares what today's
// `lungfish-cli workflow run nf-core/viralrecon` launches with what the Viral Recon descriptor writes for the same
// launch, the contract of docs/contracts/ADDING-A-NEXTFLOW-WORKFLOW.md. Each difference it finds is declared here
// with its reason, the lane whose change closes it, and how many found differences it matches in each case. The
// class fails on a difference no entry declares and on an entry that matches another number than its count, so the
// list only shrinks. The commit that closes a difference deletes its entry, which `declared but gone` asks for.

import Foundation

/// One case of the contract parity class.
enum ViralReconContractCase: String, CaseIterable, Sendable {
    /// Today's route on the stand-in with the docker executor, the one executor it runs.
    case docker
    /// A bare `workflow run` call on a built CLI whose lock holds no Viral Recon pin.
    case lockWithoutPin
}

/// One declared difference.
struct ViralReconContractKnownDifference: Sendable {
    let counts: [ViralReconContractCase: Int]
    /// The id of the difference, where `*` stands for any run of characters.
    let id: String
    let reason: String
    let closedBy: String

    func matches(_ difference: String) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: id).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return difference.range(of: pattern, options: .regularExpression) != nil
    }
}

enum ViralReconContractKnownDifferences {
    // B31's pin commit closed fit difference 3 of the contract (section 1), the last entry (N2). A lock without the
    // pin now refuses the run with 126, as the descriptor does, so any difference found again fails as not declared.
    static let all: [ViralReconContractKnownDifference] = []

    /// One line per found difference no entry declares, and per entry of `parityCase` that matches another number
    /// of found differences than its count.
    static func failures(found: [String], parityCase: ViralReconContractCase) -> [String] {
        let declared = all.filter { $0.counts[parityCase] != nil }
        var lines = found.filter { difference in !declared.contains { $0.matches(difference) } }.map { "not declared: \($0)" }
        for entry in declared {
            let matched = found.filter(entry.matches)
            let count = entry.counts[parityCase] ?? 0
            if matched.isEmpty {
                lines.append("declared but gone, delete \(parityCase.rawValue) from the entry (closed by \(entry.closedBy)): \(entry.id)")
            } else if matched.count != count {
                lines.append("\(matched.count) differences match, \(count) declared for \(parityCase.rawValue): \(entry.id)")
            }
        }
        return lines
    }
}
