// AlignmentConsensusNormalizer.swift - Enforces the evidence-only postcondition for a caller's reference
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// Enforces the evidence-only postcondition for a caller's reference projection.
public enum AlignmentConsensusNormalizer {
    /// Aligns caller bases to the request and masks every coordinate below the
    /// effective depth threshold. This operation never accepts reference bases.
    public static func normalize(
        caller: AlignmentDataProvider.ConsensusFASTAResult,
        depth: [DepthPoint],
        request: AlignmentConsensusRequest
    ) throws -> AlignmentConsensusResult {
        guard request.insertionPolicy == .omit,
              request.deletionPolicy == .n,
              let callerStart = caller.headerStart,
              !request.chromosome.isEmpty,
              request.start >= 0,
              request.end > request.start else {
            throw AlignmentFetchError.consensusCoordinateMismatch
        }

        let callerBases = Array(caller.sequence)
        let callerEnd = callerStart + callerBases.count
        guard callerStart <= request.start, callerEnd == request.end else {
            throw AlignmentFetchError.consensusCoordinateMismatch
        }

        let referenceLength = request.end - request.start
        let callerOffset = request.start - callerStart
        guard callerOffset >= 0, callerOffset + referenceLength == callerBases.count else {
            throw AlignmentFetchError.consensusCoordinateMismatch
        }

        var depths = Array(repeating: 0, count: referenceLength)
        for point in depth where point.chromosome == request.chromosome && point.position >= request.start && point.position < request.end {
            depths[point.position - request.start] = point.depth
        }

        // Keep the postcondition threshold identical to `samtools consensus`,
        // whose `-d` value is clamped to one at process construction.
        let minimumDepth = max(1, request.filters.minimumDepth)
        let normalizedBases = (0..<referenceLength).map { offset -> Character in
            guard depths[offset] >= minimumDepth else { return "N" }
            let callerBase = callerBases[callerOffset + offset]
            return callerBase == "*" ? "N" : callerBase
        }
        let sequence = String(normalizedBases)
        return AlignmentConsensusResult(
            sequence: sequence,
            referenceLength: referenceLength,
            allLowDepth: depths.allSatisfy { $0 < minimumDepth }
        )
    }
}
