// TwelveSAbundanceReassigner.swift — abundant-explanation-wins reassignment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reassigns cross-species ambiguous 12S reads (identical sequence shared by
/// more than one species) to the most-abundant candidate species, mirroring the
/// chimera "abundant explanation wins" rule.
///
/// **Per-sample** decision (expert-adjudicated): the winner is chosen from each
/// sample's own unambiguous read totals, so a species abundant in one sample
/// never claims another sample's reads. A pooled (global) fallback applies only
/// when a sample has no candidate clearing the policy locally, and even then
/// only credits the global winner if it has nonzero presence in that sample.
///
/// Pure and deterministic: iterates sequences, samples, and species in sorted
/// order so the result is reproducible.
public enum TwelveSAbundanceReassigner {

    /// How strong a lead the winning candidate must have over the runner-up.
    public enum ResolutionPolicy: Equatable, Sendable {
        /// Strict plurality: winner strictly greater than every other candidate, and `> 0`.
        case anyNonzeroLead
        /// Winner must beat the runner-up by `minFoldRatio` and reach `absoluteFloor` reads.
        case conservative(minFoldRatio: Double, absoluteFloor: Int)
    }

    public enum Decision: Equatable, Sendable {
        case perSample
        case pooled
    }

    public struct Move: Equatable, Sendable {
        public let sequence: String
        public let sample: String
        public let toSpecies: String
        public let toTarget: String
        public let reads: Int
        public let decidedBy: Decision
    }

    public struct Result: Sendable {
        public var countsByTarget: [String: [String: Int]]
        public var unresolvedCounts: [String: [String: Int]]
        public var moves: [Move]
    }

    public static func reassign(
        ambiguousCandidates: [String: [String]],
        unresolvedCounts: [String: [String: Int]],
        countsByTarget: [String: [String: Int]],
        speciesForTarget: [String: String],
        canonicalTargetForSpecies: [String: String],
        policy: ResolutionPolicy = .anyNonzeroLead
    ) -> Result {
        var counts = countsByTarget
        var unresolved = unresolvedCounts
        var moves: [Move] = []

        // Per-species per-sample and global unambiguous totals (the abundance signal).
        var perSampleTotal: [String: [String: Int]] = [:]   // species → sample → reads
        var globalTotal: [String: Int] = [:]                // species → reads
        for (targetID, bySample) in countsByTarget {
            guard let species = speciesForTarget[targetID] else { continue }
            for (sampleID, reads) in bySample {
                perSampleTotal[species, default: [:]][sampleID, default: 0] += reads
                globalTotal[species, default: 0] += reads
            }
        }

        for sequence in ambiguousCandidates.keys.sorted() {
            guard let candidateTargets = ambiguousCandidates[sequence],
                  let bySample = unresolved[sequence] else { continue }
            let candidateSpecies = Set(candidateTargets.compactMap { speciesForTarget[$0] }).sorted()
            guard candidateSpecies.count >= 2 else { continue } // no cross-species decision

            for sampleID in bySample.keys.sorted() {
                guard let reads = bySample[sampleID], reads > 0 else { continue }

                // Tier 1: decide using this sample's own unambiguous totals.
                if let winner = winner(
                    among: candidateSpecies,
                    totals: { perSampleTotal[$0]?[sampleID] ?? 0 },
                    policy: policy
                ), let toTarget = canonicalTargetForSpecies[winner] {
                    credit(&counts, toTarget: toTarget, sampleID: sampleID, reads: reads)
                    removeUnresolved(&unresolved, sequence: sequence, sampleID: sampleID)
                    moves.append(Move(sequence: sequence, sample: sampleID, toSpecies: winner,
                                      toTarget: toTarget, reads: reads, decidedBy: .perSample))
                    continue
                }

                // Tier 2: pooled fallback — global winner, but only if present locally.
                if let winner = winner(
                    among: candidateSpecies,
                    totals: { globalTotal[$0] ?? 0 },
                    policy: policy
                ), (perSampleTotal[winner]?[sampleID] ?? 0) > 0,
                   let toTarget = canonicalTargetForSpecies[winner] {
                    credit(&counts, toTarget: toTarget, sampleID: sampleID, reads: reads)
                    removeUnresolved(&unresolved, sequence: sequence, sampleID: sampleID)
                    moves.append(Move(sequence: sequence, sample: sampleID, toSpecies: winner,
                                      toTarget: toTarget, reads: reads, decidedBy: .pooled))
                }
                // else: leave unassigned (ambiguous) in this sample.
            }
        }

        return Result(countsByTarget: counts, unresolvedCounts: unresolved, moves: moves)
    }

    /// Returns the winning species among `candidates` per `policy`, using `totals`
    /// to read each candidate's unambiguous read count, or `nil` if none qualifies.
    private static func winner(
        among candidates: [String],
        totals: (String) -> Int,
        policy: ResolutionPolicy
    ) -> String? {
        let ranked = candidates
            .map { (species: $0, total: totals($0)) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.species < $1.species }
        guard let top = ranked.first else { return nil }
        let runnerUp = ranked.count > 1 ? ranked[1].total : 0
        // A genuine winner needs a strict numeric lead (no exact tie at the top).
        guard top.total > runnerUp else { return nil }

        switch policy {
        case .anyNonzeroLead:
            return top.total > 0 ? top.species : nil
        case let .conservative(minFoldRatio, absoluteFloor):
            guard top.total >= absoluteFloor else { return nil }
            // runnerUp == 0 → ratio trivially satisfied; the floor guards that case.
            guard runnerUp == 0 || Double(top.total) >= minFoldRatio * Double(runnerUp) else { return nil }
            return top.species
        }
    }

    private static func credit(_ counts: inout [String: [String: Int]], toTarget: String, sampleID: String, reads: Int) {
        counts[toTarget, default: [:]][sampleID, default: 0] += reads
    }

    private static func removeUnresolved(_ unresolved: inout [String: [String: Int]], sequence: String, sampleID: String) {
        unresolved[sequence]?.removeValue(forKey: sampleID)
        if unresolved[sequence]?.isEmpty == true {
            unresolved.removeValue(forKey: sequence)
        }
    }
}
