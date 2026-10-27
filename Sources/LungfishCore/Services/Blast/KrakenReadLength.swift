// KrakenReadLength.swift - The lengths kraken2 recorded for a read, and whether the records found agree with them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One length kraken2 recorded for a read (BIO-READ-IDENTITY 4.1, Phase 3.0 lane READ-IDENTITY).
///
/// kraken2's per-read output keeps each read's length in its fourth column: `L` for a read it read alone, `L|L` for
/// mate 1 and mate 2 of a pair it read with `--paired`, and `L|0` for a single read the run gave as a pair with an
/// empty mate 2. Extract and BLAST take a result's reads by name from whatever file sits at the place the result
/// names, so they compare the records they find with these lengths. Trimming, filtering and basecalling again keep
/// read names and change lengths or drop reads, and a refusal then says so in words.
public struct KrakenReadLength: Sendable, Equatable {
    /// The mate the length belongs to: 1 or 2 for a pair, the mate a `/1` or `/2` suffix of the read ID names, or
    /// nil for a read with neither.
    public let mate: Int?
    public let length: Int

    public init(mate: Int?, length: Int) {
        self.mate = mate
        self.length = length
    }

    /// The lengths of one per-read line, from its length column and the mate its read ID names, if any.
    public static func lengths<S: StringProtocol>(column: S, mateInID: Int?) -> [KrakenReadLength] {
        let parts = column.split(separator: "|", omittingEmptySubsequences: false)
        if parts.count == 2, let first = Int(parts[0]), let second = Int(parts[1]) {
            guard second > 0 else { return [KrakenReadLength(mate: mateInID, length: first)] }
            return [KrakenReadLength(mate: 1, length: first), KrakenReadLength(mate: 2, length: second)]
        }
        guard parts.count == 1, let length = Int(column) else { return [] }
        return [KrakenReadLength(mate: mateInID, length: length)]
    }

    /// Whether `found`, the records found under one read ID in the order they were read, each with the mate its
    /// header or its file names, are the reads kraken2 recorded as `expected`. A record whose mate is unnamed takes
    /// the next mate number, as an interleaved file stores a pair. When the mates cannot be matched one to one,
    /// because kraken2 named fewer reads under the ID than were found and named no mate, every recorded length must
    /// be among the lengths found.
    public static func agree(expected: [KrakenReadLength], found: [KrakenReadLength]) -> Bool {
        guard !expected.isEmpty else { return true }
        var foundByMate: [Int: Int] = [:]
        for record in found {
            let mate = record.mate ?? ((foundByMate.keys.max() ?? 0) + 1)
            if foundByMate[mate] == nil { foundByMate[mate] = record.length }
        }
        if expected.allSatisfy({ $0.mate != nil }) || expected.count == found.count {
            return expected.enumerated().allSatisfy { index, read in foundByMate[read.mate ?? index + 1] == read.length }
        }
        var pool = found.map(\.length)
        for read in expected {
            guard let index = pool.firstIndex(of: read.length) else { return false }
            pool.remove(at: index)
        }
        return true
    }
}

/// The tally of a read check: how many reads a selection names, how many of them are not where the result names
/// them, and how many are there with another length than kraken2 recorded. A pair counts once, as a fragment.
public struct KrakenReadCheck: Sendable, Equatable {
    public private(set) var named = 0
    public private(set) var missing = 0
    public private(set) var otherLength = 0

    public init() {}

    /// The tally of `named` reads none of which was found.
    public static func noneFound(of named: Int) -> KrakenReadCheck {
        var check = KrakenReadCheck()
        check.named = named
        check.missing = named
        return check
    }

    /// Whether every read named was found with the lengths kraken2 recorded.
    public var passes: Bool { missing == 0 && otherLength == 0 }

    /// Counts one read ID: `expected` are kraken2's lengths and `found` the records found under it.
    public mutating func add(expected: [KrakenReadLength], found: [KrakenReadLength]) {
        named += 1
        if found.isEmpty {
            missing += 1
        } else if !KrakenReadLength.agree(expected: expected, found: found) {
            otherLength += 1
        }
    }
}

/// A BLAST draw that found reads missing or with another length than kraken2 recorded, so it built no request
/// (BIO-READ-IDENTITY 4.1). The app and `lungfish-cli blast verify` turn it into words that name the reads' place.
public struct KrakenReadsChanged: Error, Sendable, Equatable {
    public let check: KrakenReadCheck

    public init(check: KrakenReadCheck) {
        self.check = check
    }
}
