// ViewerFigureReadSample.swift - The fixed read sample of a viewer figure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The read sample of a figure (BIO-Q-G3 item 9). It keeps the strand split of
/// `ReadTrackRenderer.downsample`, each strand's share in proportion to its count, and picks the
/// reads within each strand by a reservoir sample driven by a SplitMix64 stream with a stated
/// seed, so the same reads in the same order give the same sample in every render. The live
/// view's sample stays random, since it is not a figure.
public enum ViewerFigureReadSample {
    /// The seed of each strand's SplitMix64 stream.
    public static let seed: UInt64 = 0x5EED_1329

    /// The rule a `readSample` omission names.
    public static func rule(maxReads: Int) -> String {
        "max \(maxReads) reads, a SplitMix64 reservoir sample within each strand, seed 0x\(String(seed, radix: 16, uppercase: true))"
    }

    /// At most `maxReads` of `reads`, sorted by position, and the count before sampling.
    public static func sample(_ reads: [AlignedRead], maxReads: Int) -> (reads: [AlignedRead], totalCount: Int) {
        guard reads.count > maxReads else { return (reads, reads.count) }
        let forward = reads.filter { !$0.isReverse }
        let reverse = reads.filter(\.isReverse)
        let forwardShare = Int(Double(maxReads) * Double(forward.count) / Double(reads.count))
        var result = reservoir(forward, count: forwardShare) + reservoir(reverse, count: maxReads - forwardShare)
        result.sort { $0.position < $1.position }
        return (result, reads.count)
    }

    /// Algorithm R over `source`, where element `i` replaces slot `j` when `j < count`, with `j`
    /// the high 64 bits of the stream's next value times `i + 1`.
    static func reservoir(_ source: [AlignedRead], count: Int) -> [AlignedRead] {
        guard count > 0 else { return [] }
        guard source.count > count else { return source }
        var stream = SplitMix64(state: seed)
        var kept = Array(source.prefix(count))
        for index in count..<source.count {
            let slot = Int(stream.next().multipliedFullWidth(by: UInt64(index + 1)).high)
            if slot < count { kept[slot] = source[index] }
        }
        return kept
    }
}

/// The SplitMix64 generator of Steele, Lea and Flood (2014).
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
