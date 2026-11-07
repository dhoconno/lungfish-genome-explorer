// DemultiplexChanceFloor+Run.swift - The chance floor of a search of the read bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexChanceFloor {
    /// One barcode's reads against the floor.
    public struct BarcodeCount: Sendable, Equatable {
        public let barcodeID: String
        public let readCount: Int
        /// The most reads chance gives this barcode at its share of the kit's tail. A count above it beats the floor.
        public let chanceCeiling: Int
        public var beatsTheFloor: Bool { readCount > chanceCeiling }
    }

    /// What the chance count of a run was measured on (BIO-DEMUX-NULL item 9).
    public enum Null: String, Sendable, Equatable {
        /// The first bases of the run's own unassigned reads, with a margin measured on decoy barcodes in those reads.
        case startComposition = "start-composition"
        /// Uniform random bases, when the run cannot measure its own: too few reads without a barcode, a kit whose barcodes
        /// are too short or too crowded for decoys, a side with three or more errors, or no unassigned reads to read (item 6).
        case randomBases = "random-bases"
    }

    /// The floor of one run of the search of the read bases.
    public struct Outcome: Sendable, Equatable {
        public let readsSearched: Int
        /// The reads the floor counts as chance trials, the reads that carry no barcode (BIO-DEMUX-FLOOR item 4).
        public let chanceTrials: Int
        public let barcodes: [BarcodeCount]
        /// What the chance share of each barcode was measured on.
        public var null: Null = .randomBases
        /// The factor over the composition's chance share, the decoy margin, 1 on random bases.
        public var margin: Double = 1
        /// The windows of the unassigned reads the composition was tallied from, 0 on random bases.
        public var compositionReads: Int = 0
        public var anyBarcodeBeatsTheFloor: Bool { barcodes.contains(where: \.beatsTheFloor) }
        /// Barcodes with reads whose count lies at or below the floor. They keep their outputs when another barcode
        /// beats the floor, and the summary and the record name them with their counts (ARCH, L5).
        public var barcodesWithinChance: [BarcodeCount] { barcodes.filter { $0.readCount > 0 && !$0.beatsTheFloor } }
    }

    /// The floor for the cutadapt adapter lines of each barcode (`patterns`), the reads each holds and the reads
    /// searched, with a chance share for uniform random bases. A paired file places both mates by a fragment's one
    /// call, so its chance unit is the fragment.
    ///
    /// A chance match comes only from a read that carries no barcode, and such a read stays unassigned with chance
    /// `1 - kitShare`, so the trials are `min(searched, ceil(unassigned / (1 - kitShare)))`, or every read searched
    /// when the kit's shares reach one (BIO-DEMUX-FLOOR item 4). Counting every read searched named real samples of
    /// an even pool as chance.
    public static func evaluate(
        patterns: [String: [String]],
        counts: [String: Int],
        readsSearched: Int,
        unassigned: Int,
        errorRate: Double,
        allowsIndels: Bool,
        pairedFragments: Bool
    ) -> Outcome {
        evaluateCore(
            patterns: patterns, counts: counts, readsSearched: readsSearched, unassigned: unassigned, errorRate: errorRate,
            allowsIndels: allowsIndels, pairedFragments: pairedFragments, compositions: [], margin: 1, compositionReads: 0
        )
    }

    /// The floor of `evaluate` with the start composition of each mate searched (empty for uniform random bases). A barcode's
    /// share is `min(1, max(uniformShare, margin x compositionShare))` for its lines that are one `^`-anchored side, and the
    /// uniform share for any other line (BIO-DEMUX-NULL items 5 and 6). The kit's share, for the trials, sums the unscaled
    /// composition shares. A fragment is read in each mate, so its share is `1 - (1 - p1) x (1 - p2)` (item 7).
    static func evaluateCore(
        patterns: [String: [String]],
        counts: [String: Int],
        readsSearched: Int,
        unassigned: Int,
        errorRate: Double,
        allowsIndels: Bool,
        pairedFragments: Bool,
        compositions: [[[Double]]],
        margin: Double,
        compositionReads: Int
    ) -> Outcome {
        let tail = kitTail / Double(max(1, patterns.count))
        let unit = pairedFragments ? 2 : 1
        let measured = !compositions.isEmpty
        let shares = patterns.keys.sorted().map { barcodeID -> (id: String, scaled: Double, plain: Double) in
            let lines = patterns[barcodeID] ?? []
            guard measured else {
                let read = chanceProbability(ofLines: lines, errorRate: errorRate, allowsIndels: allowsIndels)
                let fragment = 1 - pow(1 - read, Double(unit))
                return (barcodeID, fragment, fragment)
            }
            let startLines = lines.filter(Self.isStartOnlyLine)
            let otherLines = lines.filter { !Self.isStartOnlyLine($0) }
            let other = chanceProbability(ofLines: otherLines, errorRate: errorRate, allowsIndels: allowsIndels)
            let uniform = chanceProbability(ofLines: startLines, errorRate: errorRate, allowsIndels: allowsIndels)
            let plain = (0..<unit).map { mate -> Double in
                let composition = compositions[min(mate, compositions.count - 1)]
                return min(1, other + chanceProbability(
                    ofLines: startLines, errorRate: errorRate, allowsIndels: allowsIndels, composition: composition
                ))
            }
            let scaled = plain.map { mate in min(1, other + max(uniform, margin * (mate - other))) }
            return (
                barcodeID, 1 - scaled.reduce(1) { $0 * (1 - $1) }, 1 - plain.reduce(1) { $0 * (1 - $1) }
            )
        }
        let kitShare = shares.reduce(0) { $0 + $1.plain }
        let searchedUnits = readsSearched / unit
        let trials = kitShare >= 1
            ? searchedUnits
            : min(searchedUnits, Int((Double(unassigned / unit) / (1 - kitShare)).rounded(.up)))
        let barcodes = shares.map { share -> BarcodeCount in
            let ceiling = unit * chanceCeiling(trials: trials, probability: share.scaled, tail: tail)
            return BarcodeCount(barcodeID: share.id, readCount: counts[share.id] ?? 0, chanceCeiling: ceiling)
        }
        return Outcome(
            readsSearched: readsSearched, chanceTrials: trials * unit, barcodes: barcodes,
            null: measured ? .startComposition : .randomBases, margin: measured ? margin : 1,
            compositionReads: measured ? compositionReads : 0
        )
    }

    /// Whether a cutadapt line is one `^`-anchored side, the line whose chance the floor measures on the read starts.
    static func isStartOnlyLine(_ line: String) -> Bool {
        let spec = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
        return spec.hasPrefix("^") && !spec.hasSuffix("$") && !spec.contains("...")
    }

    /// The chance that a read of random bases matches one of `lines`, a union bound over the lines. Each side of a
    /// linked line must match, an `N` is a wildcard, and cutadapt allows `floor(errorRate x bases)` errors a side.
    /// With a `composition`, a `^`-anchored side takes the share of each base at each read position in place of 1/4.
    static func chanceProbability(
        ofLines lines: [String], errorRate: Double, allowsIndels: Bool, composition: [[Double]]? = nil
    ) -> Double {
        var total = 0.0
        for line in lines {
            let spec = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            var probability = 1.0
            for side in spec.components(separatedBy: "...") {
                let anchoredStart = side.hasPrefix("^")
                let anchoredEnd = side.hasSuffix("$")
                let text = side.replacingOccurrences(of: "\\{[0-9]+\\}", with: "", options: .regularExpression)
                var bases = text.uppercased().compactMap { "ACGT".firstIndex(of: $0).map { UInt8("ACGT".distance(from: "ACGT".startIndex, to: $0)) } }
                if anchoredEnd && !anchoredStart { bases.reverse() }
                let errors = Int((errorRate * Double(bases.count)).rounded(.down))
                let anchored = anchoredMatchProbability(
                    bases, errors: errors, allowsIndels: allowsIndels,
                    composition: anchoredStart && !anchoredEnd ? composition : nil
                )
                // A side anchored at neither end may start anywhere in a read, bounded at 300 starts.
                probability *= anchoredStart || anchoredEnd ? anchored : min(1, 300 * anchored)
            }
            total += probability
        }
        return min(1, total)
    }

    /// The share of `base` at read position `position`, a quarter where the composition does not reach.
    private static func share(_ composition: [[Double]]?, _ position: Int, _ base: UInt8) -> Double {
        guard let composition, position < composition.count else { return 0.25 }
        return composition[position][Int(base)]
    }

    /// The chance that random bases begin with `pattern` at `errors` errors or fewer, exact by a dynamic program
    /// over the edit-distance columns a read's bases can reach. A `composition` replaces the quarter chance of each base
    /// with the share of that base at that read position (BIO-DEMUX-NULL item 2), and `nil` gives the uniform number.
    static func anchoredMatchProbability(
        _ pattern: [UInt8], errors: Int, allowsIndels: Bool, composition: [[Double]]? = nil
    ) -> Double {
        let length = pattern.count
        guard length > errors else { return 1 }
        if errors == 0 {
            guard composition != nil else { return pow(0.25, Double(length)) }
            return (0..<length).reduce(1.0) { $0 * share(composition, $1, pattern[$1]) }
        }
        guard allowsIndels else {
            if composition != nil {
                var byMismatches = [Double](repeating: 0, count: errors + 1)
                byMismatches[0] = 1
                for index in 0..<length {
                    let match = share(composition, index, pattern[index])
                    var next = [Double](repeating: 0, count: errors + 1)
                    for count in 0...errors {
                        next[count] += byMismatches[count] * match
                        if count < errors { next[count + 1] += byMismatches[count] * (1 - match) }
                    }
                    byMismatches = next
                }
                return min(1, byMismatches.reduce(0, +))
            }
            var sum = 0.0
            var choose = 1.0
            for count in 0...errors {
                if count > 0 { choose *= Double(length - count + 1) / Double(count) }
                sum += choose * pow(3, Double(count))
            }
            return min(1, sum / pow(4, Double(length)))
        }
        let cap = UInt8(errors + 1)
        var start = [UInt8](repeating: cap, count: length + 1)
        for index in 0...length { start[index] = UInt8(min(index, errors + 1)) }
        var states: [[UInt8]: Double] = [start: 1]
        var matched = 0.0
        for step in 0..<(length + errors) where !states.isEmpty {
            var next: [[UInt8]: Double] = [:]
            for (column, probability) in states {
                for base in UInt8(0)..<4 {
                    let weight = probability * share(composition, step, base)
                    var row = [UInt8](repeating: cap, count: length + 1)
                    row[0] = min(column[0] + 1, cap)
                    for index in 1...length {
                        let substitution = column[index - 1] + (pattern[index - 1] == base ? 0 : 1)
                        row[index] = min(substitution, column[index] + 1, row[index - 1] + 1, cap)
                    }
                    if row[length] <= UInt8(errors) {
                        matched += weight
                    } else if row.contains(where: { $0 < cap }) {
                        next[row, default: 0] += weight
                    }
                }
            }
            states = next
        }
        return min(1, matched)
    }
}

extension DemultiplexingPipeline {
    /// Applies the chance floor to a search of the read bases with the bare index or barcode, the search that gave
    /// reads a barcode by chance (L5 of the 3.3 tally). The chance is measured on the first bases of the run's own
    /// unassigned reads (BIO-DEMUX-NULL), and on random bases when the run keeps none to measure. A run in which no
    /// barcode beats the floor throws before its manifest is written, so its staging folder is discarded and no output
    /// is published. Other contexts carry flanking adapters whose chance share is far below one read, and return nil.
    func requireBarcodesAboveChance(
        config: DemultiplexConfig,
        adapterFASTA: URL,
        counts: [String: Int],
        readsSearched: Int,
        unassigned: Int,
        paired: Bool,
        unassignedReadsURL: URL?
    ) async throws -> DemultiplexChanceFloor.Outcome? {
        guard config.demuxAdapterContext is BareAdapterContext else { return nil }
        // A run that searched no reads has no barcode with reads to name, so the floor has nothing to judge.
        guard readsSearched > 0 else { return nil }
        var patterns: [String: [String]] = [:]
        var name = ""
        for line in try String(contentsOf: adapterFASTA, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            if line.hasPrefix(">") {
                name = canonicalAdapterName(String(line.dropFirst()))
            } else {
                patterns[name, default: []].append(String(line))
            }
        }
        let tallies = try await unassignedStartTallies(
            readsURL: unassignedReadsURL, patterns: patterns, errorRate: config.effectiveErrorRate,
            allowsIndels: !config.useNoIndels, paired: paired
        )
        let outcome = DemultiplexChanceFloor.evaluate(
            patterns: patterns,
            counts: counts,
            readsSearched: readsSearched,
            unassigned: unassigned,
            errorRate: config.effectiveErrorRate,
            allowsIndels: !config.useNoIndels,
            pairedFragments: paired,
            unassignedStarts: tallies
        )
        guard outcome.anyBarcodeBeatsTheFloor else {
            throw DemultiplexError.noBarcodeAboveChance(kitName: config.barcodeKit.displayName)
        }
        return outcome
    }

    /// The start composition of the first unassigned reads and the decoy counts of every one, one tally a mate
    /// (DEMUX-FLOOR-DECOY-SCALE). The run passes the FASTQ that holds every unassigned read, cutadapt's output in virtual
    /// mode, whose bundle keeps a 1,000-read preview, and read before a discarded bundle is removed (DEMUXNULL-SWIFT B1). No
    /// tally is returned when there is no such file, and the floor then keeps to random bases.
    private func unassignedStartTallies(
        readsURL: URL?, patterns: [String: [String]], errorRate: Double, allowsIndels: Bool, paired: Bool
    ) async throws -> [DemultiplexChanceFloor.StartTally] {
        guard let readsURL, let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: readsURL) else { return [] }
        return try await DemultiplexChanceFloor.unassignedStartTallies(
            fastqURL: fastqURL, patterns: patterns, errorRate: errorRate, allowsIndels: allowsIndels, paired: paired
        )
    }
}
