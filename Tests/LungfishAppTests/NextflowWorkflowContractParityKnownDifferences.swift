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
    /// The argument builder the route launches with, on the requests `workflow run` never makes.
    case builder
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
    /// The commit of A30 M2 that takes the descriptor's argv as the launch (N1).
    static let descriptorArgv = "A30 M2, the descriptor's argv as the launch (N1)"

    static let all: [ViralReconContractKnownDifference] = [
        // Fit difference 1 of the contract (section 1).
        ViralReconContractKnownDifference(
            counts: [.builder: 2],
            id: "builder: *--input*",
            reason: "The request writes no --input when it has no input and joins several inputs with commas (NFCoreRunRequest.effectiveParams), where the descriptor writes the one samplesheet. workflow run always passes one samplesheet, so only the builder shows it",
            closedBy: "A30 M2, no --input without input (fit difference 1)"
        ),
        // Fit difference 2 of the contract (section 1).
        ViralReconContractKnownDifference(
            counts: [.docker: 1],
            id: "argv: -c after the parameters, the contract writes it before run",
            reason: "workflow run appends the resource-limit config (NFCoreResourceLimits.Plan.nextflowArguments) after the sorted parameters, where the descriptor writes every -c file before run",
            closedBy: "A30 M2, -c before run (fit difference 2)"
        ),
        // Fit difference 3 of the contract (section 1).
        ViralReconContractKnownDifference(
            counts: [.lockWithoutPin: 1],
            id: "lock without the pin: the route launches -r 3.0.0 where the contract refuses with 126",
            reason: "NFCoreSupportedWorkflowCatalog falls back to 3.0.0 when the lock holds no nf-core-viralrecon pin, where the descriptor refuses the run (N4)",
            closedBy: "B31, the commit that retires the four 3.0.0 homes (N2)"
        ),
        // Not among the contract's three. The fit test passes a work folder in the request, which the request
        // writes ahead of the profile, but workflow run passes none and appends the scratch's.
        ViralReconContractKnownDifference(
            counts: [.docker: 1],
            id: "argv: -work-dir after the parameters, the contract writes it after -r",
            reason: "Without --workdir, workflow run appends -work-dir with the scratch's work folder after the parameters and the -c file (RunSubcommand+NFCore.swift), where the descriptor writes the work folder ahead of the profile",
            closedBy: descriptorArgv
        ),
    ]

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
