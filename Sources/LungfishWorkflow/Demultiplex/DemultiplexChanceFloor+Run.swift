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

    /// The floor of one run of the search of the read bases.
    public struct Outcome: Sendable, Equatable {
        public let readsSearched: Int
        /// The reads the floor counts as chance trials, the reads that carry no barcode (BIO-DEMUX-FLOOR item 4).
        public let chanceTrials: Int
        public let barcodes: [BarcodeCount]
        public var anyBarcodeBeatsTheFloor: Bool { barcodes.contains(where: \.beatsTheFloor) }
        /// Barcodes with reads whose count lies at or below the floor. They keep their outputs when another barcode
        /// beats the floor, and the summary and the record name them with their counts (ARCH, L5).
        public var barcodesWithinChance: [BarcodeCount] { barcodes.filter { $0.readCount > 0 && !$0.beatsTheFloor } }
    }

    /// The floor for the cutadapt adapter lines of each barcode (`patterns`), the reads each holds and the reads
    /// searched. A paired file places both mates by a fragment's one call, so its chance unit is the fragment.
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
        let tail = kitTail / Double(max(1, patterns.count))
        let unit = pairedFragments ? 2 : 1
        let shares = patterns.keys.sorted().map { barcodeID -> (String, Double) in
            let read = chanceProbability(ofLines: patterns[barcodeID] ?? [], errorRate: errorRate, allowsIndels: allowsIndels)
            return (barcodeID, 1 - pow(1 - read, Double(unit)))
        }
        let kitShare = shares.reduce(0) { $0 + $1.1 }
        let searchedUnits = readsSearched / unit
        let trials = kitShare >= 1
            ? searchedUnits
            : min(searchedUnits, Int((Double(unassigned / unit) / (1 - kitShare)).rounded(.up)))
        let barcodes = shares.map { barcodeID, fragment -> BarcodeCount in
            let ceiling = unit * chanceCeiling(trials: trials, probability: fragment, tail: tail)
            return BarcodeCount(barcodeID: barcodeID, readCount: counts[barcodeID] ?? 0, chanceCeiling: ceiling)
        }
        return Outcome(readsSearched: readsSearched, chanceTrials: trials * unit, barcodes: barcodes)
    }

    /// The chance that a read of random bases matches one of `lines`, a union bound over the lines. Each side of a
    /// linked line must match, an `N` is a wildcard, and cutadapt allows `floor(errorRate x bases)` errors a side.
    static func chanceProbability(ofLines lines: [String], errorRate: Double, allowsIndels: Bool) -> Double {
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
                let anchored = anchoredMatchProbability(bases, errors: errors, allowsIndels: allowsIndels)
                // A side anchored at neither end may start anywhere in a read, bounded at 300 starts.
                probability *= anchoredStart || anchoredEnd ? anchored : min(1, 300 * anchored)
            }
            total += probability
        }
        return min(1, total)
    }

    /// The chance that random bases begin with `pattern` at `errors` errors or fewer, exact by a dynamic program
    /// over the edit-distance columns a read's bases can reach.
    static func anchoredMatchProbability(_ pattern: [UInt8], errors: Int, allowsIndels: Bool) -> Double {
        let length = pattern.count
        guard length > errors else { return 1 }
        if errors == 0 { return pow(0.25, Double(length)) }
        guard allowsIndels else {
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
        for _ in 0..<(length + errors) where !states.isEmpty {
            var next: [[UInt8]: Double] = [:]
            for (column, probability) in states {
                for base in UInt8(0)..<4 {
                    var row = [UInt8](repeating: cap, count: length + 1)
                    row[0] = min(column[0] + 1, cap)
                    for index in 1...length {
                        let substitution = column[index - 1] + (pattern[index - 1] == base ? 0 : 1)
                        row[index] = min(substitution, column[index] + 1, row[index - 1] + 1, cap)
                    }
                    if row[length] <= UInt8(errors) {
                        matched += probability / 4
                    } else if row.contains(where: { $0 < cap }) {
                        next[row, default: 0] += probability / 4
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
    /// reads a barcode by chance (L5 of the 3.3 tally). A run in which no barcode beats the floor throws before its
    /// manifest is written, so its staging folder is discarded and no output is published. Other contexts carry
    /// flanking adapters whose chance share is far below one read, and return nil.
    func requireBarcodesAboveChance(
        config: DemultiplexConfig,
        adapterFASTA: URL,
        counts: [String: Int],
        readsSearched: Int,
        unassigned: Int,
        paired: Bool
    ) throws -> DemultiplexChanceFloor.Outcome? {
        guard config.demuxAdapterContext is BareAdapterContext else { return nil }
        var patterns: [String: [String]] = [:]
        var name = ""
        for line in try String(contentsOf: adapterFASTA, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
            if line.hasPrefix(">") {
                name = canonicalAdapterName(String(line.dropFirst()))
            } else {
                patterns[name, default: []].append(String(line))
            }
        }
        let outcome = DemultiplexChanceFloor.evaluate(
            patterns: patterns,
            counts: counts,
            readsSearched: readsSearched,
            unassigned: unassigned,
            errorRate: config.effectiveErrorRate,
            allowsIndels: !config.useNoIndels,
            pairedFragments: paired
        )
        guard outcome.anyBarcodeBeatsTheFloor else {
            throw DemultiplexError.noBarcodeAboveChance(kitName: config.barcodeKit.displayName)
        }
        return outcome
    }
}
