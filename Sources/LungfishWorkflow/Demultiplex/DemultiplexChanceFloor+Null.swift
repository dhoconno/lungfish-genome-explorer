// DemultiplexChanceFloor+Null.swift - The chance floor measured on the file's own read starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXNULL, BIO-DEMUX-NULL. The floor of the first ruling computed chance for uniform random bases, and
// real read starts are not uniform, so it published chance matches as samples on 61 of 87 cuts of 16 public runs. The chance
// share of a barcode now comes from the start composition of the run's own unassigned reads (item 3), times a margin that
// is the largest ratio of observed to expected reads over decoy barcodes in those same reads (item 4), and never falls
// below the uniform share (item 5). A run that cannot measure its own falls back to the uniform floor (item 6).

import Foundation
import Synchronization

extension DemultiplexChanceFloor {
    /// Fewer windows than this cannot measure a start composition (item 6).
    public static let minimumCompositionWindows = 1_000
    /// Fewer decoys than this at a barcode length cannot measure a margin (item 6).
    public static let minimumDecoys = 100
    /// A kit whose uniform share reaches this cannot tell a pool from a file with no barcode, since its unassigned reads
    /// all start alike and cannot measure the rest (item 6).
    public static let saturatedKitShare = 0.5
    /// The margin never falls below this (item 4).
    public static let minimumMargin = 2.0
    /// A decoy sets the margin only when chance at twice its composition share gives its reads with less than this tail over the run's decoys (BIO-DEMUX-SPARSE-MARGIN).
    public static let decoyTail = 0.01
    /// A side with more errors than this holds hundreds of thousands of matching read starts a decoy, so its kit keeps the
    /// floor of random bases (item 6, DEMUXNULL-BIO SF2). The walk grows about 70-fold per allowed error.
    public static let maximumDecoyErrors = 2

    /// The floor with an explicit start composition and margin, the form of the reviewer's test of real read starts.
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
        evaluateCore(
            patterns: patterns, counts: counts, readsSearched: readsSearched, unassigned: unassigned, errorRate: errorRate,
            allowsIndels: allowsIndels, pairedFragments: pairedFragments, compositions: [startComposition], margin: margin,
            compositionReads: 0
        )
    }

    /// The floor measured on the first bases of the reads that carry no barcode, one tally a mate searched. It falls back
    /// to the floor of uniform random bases when the tallies cannot measure the run's own (item 6).
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
        let unit = pairedFragments ? 2 : 1
        guard let measured = measuredNull(
            patterns: patterns, errorRate: errorRate, allowsIndels: allowsIndels, unit: unit, tallies: unassignedStarts
        ) else {
            return evaluate(
                patterns: patterns, counts: counts, readsSearched: readsSearched, unassigned: unassigned,
                errorRate: errorRate, allowsIndels: allowsIndels, pairedFragments: pairedFragments
            )
        }
        return evaluateCore(
            patterns: patterns, counts: counts, readsSearched: readsSearched, unassigned: unassigned, errorRate: errorRate,
            allowsIndels: allowsIndels, pairedFragments: pairedFragments, compositions: measured.compositions,
            margin: measured.margin, compositionReads: measured.windows
        )
    }

    /// The compositions of the mates searched, the margin the decoys set and the windows tallied.
    struct MeasuredNull {
        let compositions: [[[Double]]]
        let margin: Double
        let windows: Int
    }

    /// The null the tallies measure, or nil when the run keeps to the floor of uniform random bases (item 6): fewer than
    /// 1,000 windows a mate, a window too short or too long to use, a kit whose uniform share is 0.5 or more, a side with
    /// more than `maximumDecoyErrors` errors, or fewer than 100 decoys at a barcode length.
    static func measuredNull(
        patterns: [String: [String]], errorRate: Double, allowsIndels: Bool, unit: Int, tallies: [StartTally]
    ) -> MeasuredNull? {
        let used = Array(tallies.prefix(unit))
        let required = startWindowLength(patterns: patterns, errorRate: errorRate)
        guard used.count == unit, used.allSatisfy({
            $0.windows >= minimumCompositionWindows && $0.isPackable && $0.windowLength >= required
        }) else { return nil }
        let uniformKitShare = patterns.values.reduce(0.0) { total, lines in
            let read = chanceProbability(ofLines: lines, errorRate: errorRate, allowsIndels: allowsIndels)
            return total + (1 - pow(1 - read, Double(unit)))
        }
        guard uniformKitShare < saturatedKitShare else { return nil }
        var byLength: [Int: Set<[UInt8]>] = [:]
        for lines in patterns.values {
            for pattern in startPatterns(of: lines) where !pattern.isEmpty { byLength[pattern.count, default: []].insert(pattern) }
        }
        guard !byLength.isEmpty else { return nil }
        guard byLength.keys.allSatisfy({ allowedErrors(length: $0, errorRate: errorRate) <= maximumDecoyErrors }) else { return nil }
        var margin = minimumMargin
        var compositions: [[[Double]]] = []
        for tally in used {
            guard let composition = tally.composition, let ratio = largestDecoyRatio(
                byLength: byLength, barcodeCount: patterns.count, errorRate: errorRate, allowsIndels: allowsIndels,
                tally: tally, composition: composition
            ) else { return nil }
            margin = max(margin, ratio)
            compositions.append(composition)
        }
        return MeasuredNull(compositions: compositions, margin: margin, windows: used.reduce(0) { $0 + $1.windows })
    }

    /// The largest ratio of observed to expected reads over the decoys whose reads chance at twice their share gives with a
    /// tail under 0.01 over the decoys, nil when a length has fewer than 100 decoys. When the tally stopped at the read limit,
    /// the barcodes are counted on more reads than the decoys, so every decoy counts. A decoy sits at edit distance `2e + 1`
    /// or more from every barcode of its length, so a read it matches matches no barcode and is always among the unassigned
    /// reads. Observed is the tallied windows whose start matches the decoy at the anchored rule. Expected is the windows
    /// tallied times the decoy's chance under the composition.
    static func largestDecoyRatio(
        byLength: [Int: Set<[UInt8]>], barcodeCount: Int, errorRate: Double, allowsIndels: Bool,
        tally: StartTally, composition: [[Double]]
    ) -> Double? {
        let lengths = byLength.keys.sorted()
        let spans = lengths.map { length -> ClosedRange<Int> in
            let errors = allowedErrors(length: length, errorRate: errorRate)
            return allowsIndels ? max(1, length - errors)...(length + errors) : length...length
        }
        guard let lowest = spans.map(\.lowerBound).min(), let highest = spans.map(\.upperBound).max() else { return nil }
        let windowCounts = tally.prefixCounts(lengths: lowest...highest)
        var measured: [(ratio: Double, observed: Int, share: Double)] = []
        for length in lengths {
            let errors = allowedErrors(length: length, errorRate: errorRate)
            let decoys = decoyBank(
                length: length, errors: errors, allowsIndels: allowsIndels,
                barcodes: Array(byLength[length] ?? []), target: max(1_000, 100 * barcodeCount)
            )
            guard decoys.count >= minimumDecoys else { return nil }
            for decoy in decoys {
                var observed = 0
                var share = 0.0
                for key in decoy.keys {
                    observed += windowCounts[key] ?? 0
                    share += weight(of: key, in: composition)
                }
                if share > 0 { measured.append((Double(observed) / (share * Double(tally.windows)), observed, share)) }
            }
        }
        guard tally.coversEveryRead else { return measured.map(\.ratio).max() ?? 0 }
        let tail = decoyTail / Double(max(1, measured.count))
        for entry in measured.sorted(by: { $0.ratio > $1.ratio }) where entry.ratio > minimumMargin {
            if upperTail(trials: tally.windows, probability: min(1, minimumMargin * entry.share), from: entry.observed) < tail {
                return entry.ratio
            }
        }
        return 0
    }

    /// The chance a read begins with the prefix packed in `key`, as the product of the composition's shares.
    private static func weight(of key: UInt64, in composition: [[Double]]) -> Double {
        let length = Int(key >> 58)
        let packed = key & ((1 << 58) - 1)
        var product = 1.0
        for position in 0..<length {
            let base = Int((packed >> UInt64(2 * (length - 1 - position))) & 3)
            product *= position < composition.count ? composition[position][base] : 0.25
        }
        return product
    }

    private static let decoyCache = Mutex<[String: [AnchoredNeighbours]]>([:])

    /// The decoys of one barcode length, built once for a kit and kept, since they depend on the kit and not on the file.
    private static func decoyBank(
        length: Int, errors: Int, allowsIndels: Bool, barcodes: [[UInt8]], target: Int
    ) -> [AnchoredNeighbours] {
        let key = "\(length)|\(errors)|\(allowsIndels)|\(target)|"
            + barcodes.map { $0.map(String.init).joined() }.sorted().joined(separator: ",")
        if let cached = decoyCache.withLock({ $0[key] }) { return cached }
        let built = makeDecoys(length: length, errors: errors, allowsIndels: allowsIndels, barcodes: barcodes, target: target)
        decoyCache.withLock { $0[key] = built }
        return built
    }

    /// `target` decoys of `length` bases from a fixed-seed generator, each with 3/8 to 5/8 of its bases G or C and at edit
    /// distance `2 x errors + 1` or more from every barcode (item 4). Fewer come back when the kit leaves no room.
    private static func makeDecoys(
        length: Int, errors: Int, allowsIndels: Bool, barcodes: [[UInt8]], target: Int
    ) -> [AnchoredNeighbours] {
        var state: UInt64 = 0xDEC0_1D5E_ED00_0000 &+ UInt64(length)
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let lowGC = (3 * length + 7) / 8
        let highGC = (5 * length) / 8
        var seen = Set<[UInt8]>()
        var decoys: [AnchoredNeighbours] = []
        var attempts = 0
        while decoys.count < target, attempts < target * 60 {
            attempts += 1
            let candidate = (0..<length).map { _ in UInt8(next() % 4) }
            let gc = candidate.filter { $0 == 1 || $0 == 2 }.count
            guard gc >= lowGC, gc <= highGC, !seen.contains(candidate) else { continue }
            guard barcodes.allSatisfy({ editDistance($0, candidate) >= 2 * errors + 1 }) else { continue }
            seen.insert(candidate)
            decoys.append(AnchoredNeighbours(pattern: candidate, errors: errors, allowsIndels: allowsIndels))
        }
        return decoys
    }

    private static func editDistance(_ left: [UInt8], _ right: [UInt8]) -> Int {
        var previous = Array(0...right.count)
        for (row, leftBase) in left.enumerated() {
            var current = [row + 1]
            for (column, rightBase) in right.enumerated() {
                current.append(min(previous[column] + (leftBase == rightBase ? 0 : 1), previous[column + 1] + 1, current[column] + 1))
            }
            previous = current
        }
        return previous[right.count]
    }
}
