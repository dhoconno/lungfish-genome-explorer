// DemultiplexChanceFloor+Null.swift - The chance floor measured on the file's own read starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXNULL, BIO-DEMUX-NULL. The entry points below keep the floor of today (uniform random bases) until
// the next commit gives them the start composition and the decoy margin.

import Foundation

extension DemultiplexChanceFloor {
    /// The floor with an explicit start composition and margin, the form the reviewer's test of real read starts calls.
    public static func evaluate(
        patterns: [String: [String]],
        counts: [String: Int],
        readsSearched: Int,
        unassigned: Int,
        errorRate: Double,
        allowsIndels: Bool,
        pairedFragments: Bool,
        startComposition: [[Double]],
        margin: Double
    ) -> Outcome {
        evaluate(
            patterns: patterns, counts: counts, readsSearched: readsSearched, unassigned: unassigned,
            errorRate: errorRate, allowsIndels: allowsIndels, pairedFragments: pairedFragments
        )
    }

    /// The floor measured on the first bases of the reads that carry no barcode, one tally a mate.
    public static func evaluate(
        patterns: [String: [String]],
        counts: [String: Int],
        readsSearched: Int,
        unassigned: Int,
        errorRate: Double,
        allowsIndels: Bool,
        pairedFragments: Bool,
        unassignedStarts: [StartTally]
    ) -> Outcome {
        evaluate(
            patterns: patterns, counts: counts, readsSearched: readsSearched, unassigned: unassigned,
            errorRate: errorRate, allowsIndels: allowsIndels, pairedFragments: pairedFragments
        )
    }
}
