// DemultiplexFragmentCall.swift - The barcode call of a fragment from the calls of its mates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The barcode a fragment goes to, from the barcodes its two mates were
/// called alone (A9, D6).
///
/// Both demultiplex engines call each record on its own, so the two mates of
/// one fragment could land in different barcode bundles, or one in a barcode
/// and the other in unassigned. Now both mates follow the fragment's call.
///
/// | Mate calls | Fragment call |
/// |---|---|
/// | the same barcode | that barcode |
/// | one barcode, one unassigned | that barcode |
/// | two different barcodes | unassigned, both mates whole |
/// | both unassigned | unassigned |
///
/// No kit or mode defines a sample by one barcode on each mate. A dual or
/// combinatorial sample is a linked adapter that one read must carry whole,
/// and its call is the sample's name, so two different calls are two
/// different samples.
enum DemultiplexFragmentCall {
    /// What the rule did with one pair, for the run's mate summary.
    enum Outcome: Sendable, Equatable {
        case bothMatesAgree
        case oneMateCalled
        case matesDisagree
        case neitherMateCalled
    }

    /// The fragment's call from its mates' calls, `nil` meaning unassigned.
    static func call<Label: Equatable>(_ first: Label?, _ second: Label?) -> (call: Label?, outcome: Outcome) {
        switch (first, second) {
        case let (first?, second?):
            return first == second ? (first, .bothMatesAgree) : (nil, .matesDisagree)
        case let (first?, nil):
            return (first, .oneMateCalled)
        case let (nil, second?):
            return (second, .oneMateCalled)
        case (nil, nil):
            return (nil, .neitherMateCalled)
        }
    }
}

/// Counts the outcomes of a mate-aware run for its manifest.
struct DemultiplexMateCallCounter: Sendable {
    private(set) var pairs = 0
    private(set) var bothMatesAgree = 0
    private(set) var oneMateCalled = 0
    private(set) var matesDisagree = 0
    private(set) var neitherMateCalled = 0
    private(set) var singleReads = 0

    mutating func count(_ outcome: DemultiplexFragmentCall.Outcome) {
        pairs += 1
        switch outcome {
        case .bothMatesAgree: bothMatesAgree += 1
        case .oneMateCalled: oneMateCalled += 1
        case .matesDisagree: matesDisagree += 1
        case .neitherMateCalled: neitherMateCalled += 1
        }
    }

    mutating func countSingleRead() {
        singleReads += 1
    }

    mutating func add(_ other: DemultiplexMateCallCounter) {
        pairs += other.pairs
        bothMatesAgree += other.bothMatesAgree
        oneMateCalled += other.oneMateCalled
        matesDisagree += other.matesDisagree
        neitherMateCalled += other.neitherMateCalled
        singleReads += other.singleReads
    }

    var summary: DemultiplexMateCalls {
        DemultiplexMateCalls(
            pairs: pairs,
            bothMatesAgree: bothMatesAgree,
            oneMateCalled: oneMateCalled,
            matesDisagree: matesDisagree,
            neitherMateCalled: neitherMateCalled,
            singleReads: singleReads
        )
    }
}
