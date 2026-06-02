// TwelveSAbundanceReassigner.swift — abundant-explanation-wins reassignment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reassigns cross-species ambiguous 12S reads (identical sequence shared by
/// more than one species) to the most-abundant candidate species, mirroring the
/// chimera "abundant explanation wins" rule.
///
/// Policy (locked): **strict plurality, any nonzero lead wins.** The winner is
/// the candidate species whose unambiguous exact-read total (reads it won
/// elsewhere) is strictly greater than every other candidate's and is `> 0`.
/// Exact ties, all-zero, or a single distinct candidate species leave the reads
/// ambiguous/unresolved.
///
/// Pure and deterministic: iterates sequences and species in sorted order so the
/// result is reproducible.
public enum TwelveSAbundanceReassigner {

    public struct Move: Equatable, Sendable {
        public let sequence: String
        public let toSpecies: String
        public let toTarget: String
        public let reads: Int
    }

    public struct Result: Sendable {
        public var countsByTarget: [String: [String: Int]]
        public var unresolvedCounts: [String: [String: Int]]
        public var moves: [Move]
    }

    /// - Parameters:
    ///   - ambiguousCandidates: normalizedSequence → candidate target IDs.
    ///   - unresolvedCounts: normalizedSequence → (sampleID → reads) for currently-unresolved/ambiguous reads.
    ///   - countsByTarget: targetID → (sampleID → reads) of unambiguous exact reads (the abundance signal).
    ///   - speciesForTarget: targetID → species key (display name).
    ///   - canonicalTargetForSpecies: species key → the canonical target ID reads should be credited to.
    public static func reassign(
        ambiguousCandidates: [String: [String]],
        unresolvedCounts: [String: [String: Int]],
        countsByTarget: [String: [String: Int]],
        speciesForTarget: [String: String],
        canonicalTargetForSpecies: [String: String]
    ) -> Result {
        var counts = countsByTarget
        var unresolved = unresolvedCounts
        var moves: [Move] = []

        // Per-species unambiguous totals from the exact counts (abundance signal).
        var speciesTotal: [String: Int] = [:]
        for (targetID, perSample) in countsByTarget {
            guard let species = speciesForTarget[targetID] else { continue }
            speciesTotal[species, default: 0] += perSample.values.reduce(0, +)
        }

        for sequence in ambiguousCandidates.keys.sorted() {
            guard let candidateTargets = ambiguousCandidates[sequence],
                  let perSample = unresolved[sequence] else { continue }

            // Distinct candidate species (sorted for deterministic tie handling).
            let candidateSpecies = Set(candidateTargets.compactMap { speciesForTarget[$0] }).sorted()
            guard candidateSpecies.count >= 2 else { continue } // no cross-species decision

            // Find the strict-max species by unambiguous total.
            var bestSpecies: String?
            var bestTotal = 0
            var tie = false
            for species in candidateSpecies {
                let total = speciesTotal[species, default: 0]
                if total > bestTotal {
                    bestTotal = total
                    bestSpecies = species
                    tie = false
                } else if total == bestTotal && total > 0 {
                    tie = true
                }
            }
            guard let winner = bestSpecies, bestTotal > 0, !tie,
                  let toTarget = canonicalTargetForSpecies[winner] else { continue }

            // Move the reads: out of unresolved, into the winner's canonical target.
            let movedReads = perSample.values.reduce(0, +)
            for (sampleID, reads) in perSample {
                counts[toTarget, default: [:]][sampleID, default: 0] += reads
            }
            unresolved.removeValue(forKey: sequence)
            moves.append(Move(sequence: sequence, toSpecies: winner, toTarget: toTarget, reads: movedReads))
        }

        return Result(countsByTarget: counts, unresolvedCounts: unresolved, moves: moves)
    }
}
