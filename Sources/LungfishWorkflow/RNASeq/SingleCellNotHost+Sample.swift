// SingleCellNotHost+Sample.swift - One library's not-host rows, its pool's figures and each cell's q (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A cell's p is the Poisson upper tail of its default not-host UMIs at its raw UMIs times the pool's rate, BH runs over
// the library's cells, and a cell is flagged at 2 or more UMIs and q under 0.001, as `virus.py` and `mtb.py` flag it. A
// spike-in gets counts and no flag, and a bacterium with no rRNA mask reads `not computed: no rRNA mask for <extra>`.

import Foundation

/// The not-host rows of one library.
public struct SingleCellNotHostSample: Sendable, Equatable {
    /// A cell, or a barcode outside the cells with a not-host UMI, as both scripts write them.
    public struct Barcode: Sendable, Equatable {
        public var barcode: String
        /// The barcode's column in the filtered matrix from 0, or nil outside the cells.
        public var column: Int?
        public var rawUMIs: UInt64
        public var inPool: Bool
        public var genome: [SingleCellNotHostCounts]
        public var records: [SingleCellNotHostCounts]
    }

    /// A cell's test against one virus or bacterium extra.
    public struct Call: Sendable, Equatable {
        public var column: Int
        public var extra: Int
        public var p: Double?
        public var q: Double?
        /// The flag's words, empty when the cell is not flagged, or the words that say why no flag was computed.
        public var flag: String
    }

    public var sample: String
    public var cellCount: Int
    public var pool: SingleCellAmbientPool
    public var barcodes: [Barcode]
    public var calls: [Call]
    /// The pool's not-host UMIs by extra and by record, and each extra's rate, nil with no pool.
    public var poolGenome: [SingleCellNotHostCounts]
    public var poolRecords: [SingleCellNotHostCounts]
    public var rates: [Double?]
    /// Barcodes with a not-host UMI that the raw list lacks, left out as both scripts leave them.
    public var barcodesNotInRawList: Int
    /// The BAM's primary alignments over the set's records that the counter took, those it left out at an NH other than 1
    /// or with no NH, and those it left out for want of a CB or UB (BIO-NOTHOST-BARCODE item 4: a degraded result says so).
    public var alignmentsCounted = 0
    public var alignmentsMultimapped = 0
    public var alignmentsWithoutBarcode = 0

    /// What the pass counted and left out of this library, in the words of the record.
    public var leftOutWords: String {
        "\(sample): \(alignmentsCounted) alignments counted, \(alignmentsMultimapped) not at NH 1 and \(alignmentsWithoutBarcode) without a CB or UB left out, "
            + "\(barcodesNotInRawList) barcodes not in the raw list left out"
    }

    /// True when the BAM held alignments and the counter took none, or when barcodes of the BAM are not in the raw list: the
    /// two ways a library reads as no not-host RNA for want of a count, and not for want of any.
    public var needsACheck: Bool {
        (alignmentsCounted == 0 && alignmentsMultimapped + alignmentsWithoutBarcode > 0) || barcodesNotInRawList > 0
    }
}

/// The not-host pass of one import: the set's extras and records and each library's rows.
public struct SingleCellNotHostResult: Sendable, Equatable {
    public var extras: [SingleCellNotHostExtra]
    public var records: [SingleCellNotHostRecord]
    public var samples: [SingleCellNotHostSample]

    public init(extras: [SingleCellNotHostExtra], records: [SingleCellNotHostRecord], samples: [SingleCellNotHostSample]) {
        self.extras = extras
        self.records = records
        self.samples = samples
    }

    /// The extra of each record, by the order of `records`.
    public func extraNumber(ofRecord name: String) -> Int? { extras.firstIndex { $0.records.contains(name) } }
}

public enum SingleCellNotHostPass {
    /// The rows of one library from its cells in column order, its raw matrix and pool, and the BAM's tallies.
    public static func sample(
        _ sample: String, cells: [String], raw: SingleCellRawMatrix, pool: SingleCellAmbientPool,
        tallies: [String: SingleCellNotHostTally], extras: [SingleCellNotHostExtra]
    ) -> SingleCellNotHostSample {
        let recordCount = extras.reduce(0) { $0 + $1.records.count }
        let zero = SingleCellNotHostTally(genome: Array(repeating: .init(), count: extras.count), records: Array(repeating: .init(), count: recordCount))
        let inPool = Set(pool.members)
        var rows: [SingleCellNotHostSample.Barcode] = []
        var cellRows: [Int: Int] = [:]
        for (column, barcode) in cells.enumerated() {
            let index = raw.barcodes.index(of: barcode)
            let tally = tallies[barcode] ?? zero
            cellRows[column] = rows.count
            rows.append(.init(barcode: barcode, column: column, rawUMIs: index.map { raw.totals[$0] } ?? 0,
                              inPool: index.map(inPool.contains) ?? false, genome: tally.genome, records: tally.records))
        }
        let cellSet = Set(cells)
        var missing = 0
        var poolGenome = zero.genome
        var poolRecords = zero.records
        for (barcode, tally) in tallies.sorted(by: { $0.key < $1.key }) {
            guard let index = raw.barcodes.index(of: barcode) else {
                missing += 1
                continue
            }
            if inPool.contains(index) {
                for extra in extras.indices { poolGenome[extra].add(tally.genome[extra]) }
                for record in 0..<recordCount { poolRecords[record].add(tally.records[record]) }
            }
            guard !cellSet.contains(barcode) else { continue }
            rows.append(.init(barcode: barcode, column: nil, rawUMIs: raw.totals[index], inPool: inPool.contains(index),
                              genome: tally.genome, records: tally.records))
        }
        let rates: [Double?] = extras.indices.map { extra in
            pool.words == nil ? SingleCellNotHostFlag.rate(notHostUMIs: poolGenome[extra].umis, poolUMIs: pool.umis) : nil
        }
        var calls: [SingleCellNotHostSample.Call] = []
        for (extra, info) in extras.enumerated() {
            guard let words = SingleCellNotHostFlag.words(for: info.kind) else { continue }
            let why = info.kind == .bacterium && info.mask == nil ? SingleCellNotHostFlag.noMaskWords(info.name) : pool.words
            guard let rate = rates[extra], why == nil else {
                calls += cells.indices.map { .init(column: $0, extra: extra, p: nil, q: nil, flag: why ?? "") }
                continue
            }
            let found = cells.indices.map { rows[cellRows[$0] ?? 0] }
            let p = found.map { SingleCellNotHostFlag.upperTail($0.genome[extra].umis, mean: max(Double($0.rawUMIs) * rate, 1e-12)) }
            let q = SingleCellNotHostFlag.benjaminiHochberg(p)
            for column in cells.indices {
                let flagged = found[column].genome[extra].umis >= SingleCellNotHostFlag.minimumUMIs && q[column] < SingleCellNotHostFlag.qBar
                calls.append(.init(column: column, extra: extra, p: p[column], q: q[column], flag: flagged ? words : ""))
            }
        }
        return SingleCellNotHostSample(
            sample: sample, cellCount: cells.count, pool: pool, barcodes: rows, calls: calls,
            poolGenome: poolGenome, poolRecords: poolRecords, rates: rates, barcodesNotInRawList: missing)
    }
}

extension SingleCellNotHostFlag {
    /// P(X >= k) for a Poisson count of mean `mean`, `scipy.stats.poisson.sf(k - 1, mean)`: the regularized lower
    /// incomplete gamma P(k, mean), by its series below k + 1 and by the continued fraction of 1 - P above.
    public static func upperTail(_ k: Int, mean: Double) -> Double {
        guard k > 0 else { return 1 }
        guard mean > 0 else { return 0 }
        let a = Double(k)
        let scale = exp(-mean + a * log(mean) - lgamma(a))
        if mean < a + 1 {
            var term = 1 / a
            var sum = term
            var n = a
            for _ in 0..<100_000 {
                n += 1
                term *= mean / n
                sum += term
                if abs(term) < abs(sum) * 1e-17 { break }
            }
            return min(1, sum * scale)
        }
        let tiny = 1e-300
        var b = mean + 1 - a
        var c = 1 / tiny
        var d = 1 / b
        var h = d
        for i in 1..<100_000 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b
            if abs(d) < tiny { d = tiny }
            c = b + an / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 1e-16 { break }
        }
        return max(0, 1 - scale * h)
    }

    /// Benjamini-Hochberg q values in the order of `p`, as both scripts' `bh()` computes them.
    public static func benjaminiHochberg(_ p: [Double]) -> [Double] {
        let n = p.count
        let order = p.indices.sorted { p[$0] < p[$1] || (p[$0] == p[$1] && $0 < $1) }
        var q = [Double](repeating: 0, count: n)
        var running = Double.infinity
        for rank in stride(from: n - 1, through: 0, by: -1) {
            let index = order[rank]
            running = min(running, p[index] * Double(n) / Double(rank + 1))
            q[index] = min(running, 1)
        }
        return q
    }
}
