// DemultiplexChanceFloor+Tally.swift - The first bases of a file's reads and the read starts a barcode matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXNULL (BIO-DEMUX-NULL items 2 to 4). The floor measures chance on the file's own read starts, so it
// tallies the first bases of the reads that carry no barcode, and it needs the anchored matcher of the floor in two forms:
// the dynamic program that says whether one read start matches a barcode, and the set of read starts that match, which
// the decoy margin counts against the tally.
//
// Phase 3.3 lane DECOYSCALE (DEMUX-FLOOR-DECOY-SCALE, BIO-DEMUX-SPARSE-MARGIN item 9). One streaming pass counts every decoy
// over every unassigned read, the reads the barcodes are counted on, and stores no window. The start composition still
// comes from the first 200,000 records, so the sparse rule of the margin holds at every size of run.

import Foundation
import LungfishIO

extension DemultiplexChanceFloor {
    /// The most records whose first bases set a file's start composition (BIO-DEMUX-NULL item 3). The decoys are counted on
    /// every unassigned read past it (DEMUX-FLOOR-DECOY-SCALE).
    public static let compositionReadLimit = 200_000

    /// One pass over an unassigned FASTQ: the start composition of its first `compositionLimit` records and the decoy counts
    /// of every read, one tally a mate for a paired run (item 7). The mates are the adjacent records the mate pass wrote the
    /// file by (`FASTQReadLayoutClassifier.areMates`): the first of a pair goes to the first tally and the second to the
    /// second. A read with no mate beside it, such as a single read in a mixed file, belongs to neither tally, so it never
    /// moves the mates that follow it. A pass that is cancelled throws, so no tally of part of the file is returned.
    static func unassignedStartTallies(
        fastqURL: URL, patterns: [String: [String]], errorRate: Double, allowsIndels: Bool, paired: Bool,
        compositionLimit: Int = compositionReadLimit
    ) async throws -> [StartTally] {
        let empty = StartTally(patterns: patterns, errorRate: errorRate, allowsIndels: allowsIndels)
        var tallies = Array(repeating: empty, count: paired ? 2 : 1)
        var seen = 0
        var pending: FASTQRecord?
        for try await record in FASTQReader(validateSequence: false).records(from: fastqURL) {
            seen += 1
            let composing = seen <= compositionLimit
            // A kit with no decoy bank has nothing to count past the composition reads, so the rest of the file is not read.
            if !composing, empty.decoys == nil { break }
            if !paired {
                tallies[0].add(record.sequence, composing: composing)
            } else if let first = pending,
                      FASTQReadLayoutClassifier.areMates(headerText(of: first), headerText(of: record)) {
                tallies[0].add(first.sequence, composing: composing)
                tallies[1].add(record.sequence, composing: composing)
                pending = nil
            } else {
                pending = record
            }
        }
        try Task.checkCancellation()
        return tallies
    }

    /// The header line of a record, the text the mate rule reads.
    private static func headerText(of record: FASTQRecord) -> String {
        record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
    }

    /// A window packs two bits a base into 58 bits, and the top bits of a key hold the length of the prefix.
    static let maximumPackedBases = 29

    /// The bases of a read as codes, 0 to 3 for A, C, G and T and 4 for anything else, an `N` included.
    static func baseCodes(_ read: some StringProtocol) -> [UInt8] {
        read.utf8.map { byte in
            switch byte {
            case 65, 97: return 0
            case 67, 99: return 1
            case 71, 103: return 2
            case 84, 116: return 3
            default: return 4
            }
        }
    }

    /// The key of a prefix of `length` bases packed two bits a base, the first base highest.
    static func prefixKey(length: Int, packed: UInt64) -> UInt64 {
        (UInt64(length) << 58) | packed
    }

    /// The bases of every `^`-anchored side of `lines`, the sides whose chance the floor measures on the read starts.
    /// A side that is anchored at the end, or at neither end, keeps the uniform share (BIO-DEMUX-NULL item 6).
    static func startPatterns(of lines: [String]) -> [[UInt8]] {
        var patterns: [[UInt8]] = []
        for line in lines {
            let spec = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            for side in spec.components(separatedBy: "...") where side.hasPrefix("^") && !side.hasSuffix("$") {
                let text = side.replacingOccurrences(of: "\\{[0-9]+\\}", with: "", options: .regularExpression)
                patterns.append(baseCodes(text).filter { $0 < 4 })
            }
        }
        return patterns
    }

    /// The errors cutadapt allows a side of `length` bases.
    static func allowedErrors(length: Int, errorRate: Double) -> Int {
        Int((errorRate * Double(length)).rounded(.down))
    }

    /// The window the tally takes from each read: the longest `^`-anchored barcode, its errors and one more base
    /// (BIO-DEMUX-NULL item 3). It is 1 when the patterns hold no such side.
    public static func startWindowLength(patterns: [String: [String]], errorRate: Double) -> Int {
        var longest = 0
        for lines in patterns.values {
            for pattern in startPatterns(of: lines) {
                longest = max(longest, pattern.count + allowedErrors(length: pattern.count, errorRate: errorRate))
            }
        }
        return longest + 1
    }

    /// Whether the start of `read` matches `pattern` under the anchored rule of the floor: the whole pattern aligns to a
    /// prefix of the read within `errors` edits, or `errors` mismatches when indels are off. An `N` (code 4) never matches.
    static func anchoredMatch(read: [UInt8], pattern: [UInt8], errors: Int, allowsIndels: Bool) -> Bool {
        let length = pattern.count
        guard length > errors else { return true }
        guard allowsIndels else {
            guard read.count >= length else { return false }
            var mismatches = 0
            for index in 0..<length where read[index] != pattern[index] { mismatches += 1 }
            return mismatches <= errors
        }
        let cap = UInt8(errors + 1)
        var column = (0...length).map { UInt8(min($0, errors + 1)) }
        for step in 0..<min(read.count, length + errors) {
            let base = read[step]
            var row = [UInt8](repeating: cap, count: length + 1)
            row[0] = min(column[0] + 1, cap)
            for index in 1...length {
                let substitution = column[index - 1] + (pattern[index - 1] == base ? 0 : 1)
                row[index] = min(substitution, column[index] + 1, row[index - 1] + 1, cap)
            }
            if row[length] <= UInt8(errors) { return true }
            if !row.contains(where: { $0 < cap }) { return false }
            column = row
        }
        return false
    }

    /// The first bases of reads, tallied position by position for the start composition, and the windows that begin with
    /// each read start a decoy of the kit matches. A window is a read's first `windowLength` bases, and a read with an `N`
    /// among them makes no window, since a no-call read is `N` at every position and would make a product over positions
    /// rare (item 3). The decoys are counted on every window offered and the composition only on the windows of the reads
    /// that set it, and no window is kept (DEMUX-FLOOR-DECOY-SCALE).
    public struct StartTally: Sendable {
        public let windowLength: Int
        /// Reads offered, whether or not they made a window, every read of the pass.
        public private(set) var reads = 0
        /// Windows of the reads that set the composition, at most the first `compositionReadLimit` records of the pass.
        public private(set) var windows = 0
        /// Windows of every read offered, the reads the decoys are counted on and the trials of their expected counts.
        public private(set) var countedWindows = 0
        /// Per position, how many composition windows hold A, C, G and T.
        private(set) var baseCounts: [[Int]]
        /// The decoys of the kit the tally counts, nil when the kit cannot measure a margin (item 6).
        let decoys: DecoyIndex?
        /// Per slot of `decoys`, the windows that begin with that read start.
        private(set) var startCounts: [Int]

        /// An empty tally for the kit of `patterns`. Its window is the longest `^`-anchored barcode, its errors and one more
        /// base, and it counts the decoys of that kit.
        public init(patterns: [String: [String]], errorRate: Double, allowsIndels: Bool) {
            self.init(
                windowLength: DemultiplexChanceFloor.startWindowLength(patterns: patterns, errorRate: errorRate),
                decoys: DemultiplexChanceFloor.decoyIndex(patterns: patterns, errorRate: errorRate, allowsIndels: allowsIndels)
            )
        }

        init(windowLength: Int, decoys: DecoyIndex?) {
            self.windowLength = max(1, windowLength)
            baseCounts = Array(repeating: [0, 0, 0, 0], count: max(1, windowLength))
            self.decoys = decoys
            startCounts = Array(repeating: 0, count: decoys?.slots.count ?? 0)
        }

        /// Whether the window fits the packed keys the decoys are counted by.
        var isPackable: Bool { windowLength <= DemultiplexChanceFloor.maximumPackedBases }

        /// Adds a read to the composition and to the decoy counts.
        public mutating func add(_ read: String) {
            add(read, composing: true)
        }

        /// Adds a read, as base codes, to the composition and to the decoy counts.
        public mutating func add(codes: [UInt8]) {
            add(codes: codes, composing: true)
        }

        mutating func add(_ read: String, composing: Bool) {
            add(codes: DemultiplexChanceFloor.baseCodes(read.prefix(windowLength)), composing: composing)
        }

        /// Adds a read to the decoy counts, and to the composition when `composing`.
        mutating func add(codes: [UInt8], composing: Bool) {
            reads += 1
            guard codes.count >= windowLength, !codes[0..<windowLength].contains(where: { $0 > 3 }) else { return }
            countedWindows += 1
            if composing {
                for position in 0..<windowLength { baseCounts[position][Int(codes[position])] += 1 }
                windows += 1
            }
            guard let decoys else { return }
            var packed: UInt64 = 0
            for length in 1...min(windowLength, decoys.prefixLengths.upperBound) {
                packed = packed << 2 | UInt64(codes[length - 1])
                if length >= decoys.prefixLengths.lowerBound,
                   let slot = decoys.slots[DemultiplexChanceFloor.prefixKey(length: length, packed: packed)] {
                    startCounts[slot] += 1
                }
            }
        }

        /// The share of A, C, G and T at each position of the composition windows, or nil when no window was tallied.
        public var composition: [[Double]]? {
            guard windows > 0 else { return nil }
            return baseCounts.map { counts in counts.map { Double($0) / Double(windows) } }
        }

        /// The windows whose start matches each decoy at the anchored rule, in the order of `decoys.decoys`. No read start a
        /// decoy matches extends another of its own, so each window counts at most once for a decoy.
        func decoyCounts() -> [Int] {
            guard let decoys else { return [] }
            return decoys.decoys.map { decoy in
                decoy.keys.reduce(0) { total, key in total + (decoys.slots[key].map { startCounts[$0] } ?? 0) }
            }
        }
    }

    /// The decoys of a kit and one slot for each read start that any of them matches, so one pass counts every decoy with
    /// one lookup a prefix length of each read (DEMUX-FLOOR-DECOY-SCALE). Built once a kit and kept.
    final class DecoyIndex: Sendable {
        /// The decoys of every barcode length of the kit, the shortest length first.
        let decoys: [AnchoredNeighbours]
        /// The slot of each read start a decoy matches, keyed by `prefixKey`.
        let slots: [UInt64: Int]
        /// The shortest and the longest read start a decoy matches.
        let prefixLengths: ClosedRange<Int>
        /// The kit the decoys were built for, so a tally is never read for another kit.
        let kit: String

        init(decoys: [AnchoredNeighbours], prefixLengths: ClosedRange<Int>, kit: String) {
            var slots: [UInt64: Int] = [:]
            for decoy in decoys {
                for key in decoy.keys where slots[key] == nil { slots[key] = slots.count }
            }
            self.decoys = decoys
            self.slots = slots
            self.prefixLengths = prefixLengths
            self.kit = kit
        }
    }

    /// Every read start that matches a pattern at the anchored rule, kept as the shortest matching prefixes. No prefix in
    /// the set extends another, so a read start has at most one, and counting the windows that start with each prefix
    /// counts every matching window once (BIO-DEMUX-NULL item 4).
    struct AnchoredNeighbours: Sendable {
        let pattern: [UInt8]
        let errors: Int
        let allowsIndels: Bool
        /// `prefixKey` of each shortest matching prefix. Empty when the pattern cannot be packed.
        let keys: Set<UInt64>
        /// The shortest and the longest prefix a match can have.
        let lengths: ClosedRange<Int>

        init(pattern: [UInt8], errors: Int, allowsIndels: Bool) {
            self.pattern = pattern
            self.errors = errors
            self.allowsIndels = allowsIndels
            let length = pattern.count
            let longest = allowsIndels ? length + errors : length
            lengths = max(1, allowsIndels ? length - errors : length)...max(1, longest)
            var found = Set<UInt64>()
            guard longest <= DemultiplexChanceFloor.maximumPackedBases, length > errors else {
                keys = found
                return
            }
            if allowsIndels {
                let cap = UInt8(errors + 1)
                func walk(_ depth: Int, _ column: [UInt8], _ packed: UInt64) {
                    for base in UInt8(0)..<4 {
                        var row = [UInt8](repeating: cap, count: length + 1)
                        row[0] = min(column[0] + 1, cap)
                        for index in 1...length {
                            let substitution = column[index - 1] + (pattern[index - 1] == base ? 0 : 1)
                            row[index] = min(substitution, column[index] + 1, row[index - 1] + 1, cap)
                        }
                        let next = packed << 2 | UInt64(base)
                        if row[length] <= UInt8(errors) {
                            found.insert(DemultiplexChanceFloor.prefixKey(length: depth + 1, packed: next))
                        } else if depth + 1 < longest, row.contains(where: { $0 < cap }) {
                            walk(depth + 1, row, next)
                        }
                    }
                }
                walk(0, (0...length).map { UInt8(min($0, errors + 1)) }, 0)
            } else {
                func walk(_ depth: Int, _ mismatches: Int, _ packed: UInt64) {
                    if depth == length {
                        found.insert(DemultiplexChanceFloor.prefixKey(length: length, packed: packed))
                        return
                    }
                    for base in UInt8(0)..<4 {
                        let next = mismatches + (pattern[depth] == base ? 0 : 1)
                        if next <= errors { walk(depth + 1, next, packed << 2 | UInt64(base)) }
                    }
                }
                walk(0, 0, 0)
            }
            keys = found
        }

        /// Whether the start of `read`, as base codes, matches. A read with an `N` among its first bases takes the
        /// dynamic program, which counts the `N` as a mismatch.
        func matches(_ read: [UInt8]) -> Bool {
            let reach = min(read.count, lengths.upperBound)
            if read[0..<reach].contains(where: { $0 > 3 }) || keys.isEmpty {
                return DemultiplexChanceFloor.anchoredMatch(read: read, pattern: pattern, errors: errors, allowsIndels: allowsIndels)
            }
            var packed: UInt64 = 0
            for length in 1...max(1, reach) where length <= read.count {
                packed = packed << 2 | UInt64(read[length - 1])
                if length >= lengths.lowerBound, keys.contains(DemultiplexChanceFloor.prefixKey(length: length, packed: packed)) {
                    return true
                }
            }
            return false
        }
    }
}
