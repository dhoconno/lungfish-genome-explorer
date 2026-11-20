// RNASeqCellMapTierB.swift - Tier B of X4, a computed cell map against the pin by meaning (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling ADJ-SC-EMBED item 2 with BIO's items 1 to 5 of ruling TIERB-BIO. In order: (a) the sample and barcode columns
// equal the pin's by bytes and in order, (b) the route's record equals the pin's key by key but the nine keys TIERB-BIO
// item 2 names, (c) labels reach ARI of at least 0.70, unrounded, and (d) the mean share of each cell's 15 nearest
// neighbours kept reaches at least 0.50. It prints the byte result, a label line, a variable-gene line and a PCA line,
// and gives one of the four verdicts. The bars hold only for pbmc_1k_v3 at the C2 parameters.

import Foundation
@testable import LungfishWorkflow

enum RNASeqCellMapTierB {
    static let labelBar = 0.70
    static let neighbourBar = 0.50
    static let k = 15
    /// TIERB-BIO item 2, as flattened keys.
    static let leftOut: Set<String> = [
        "host.cpu_model", "host.openblas.architecture", "host.numba_cpu_name", "host.platform", "outputs.cells.tsv",
        "outputs.variable_genes.tsv", "outputs.pca_variance_ratio.tsv", "counts.clusters", "counts.cluster_sizes",
    ]

    struct Cells {
        var ids: [Substring] = []
        var x: [Double] = []
        var y: [Double] = []
        var labels: [Substring] = []
    }

    /// A table of `sample`, `barcode`, two coordinates and a label, with a header line. Coordinates are read as float32
    /// and computed in float64 (ruling ADJ-SC-EMBED, How a test reads the bars).
    static func cells(_ url: URL) throws -> Cells {
        var table = Cells()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }
            table.ids.append(line[line.startIndex..<fields[1].endIndex])
            table.x.append(Double(Float(fields[2]) ?? .nan))
            table.y.append(Double(Float(fields[3]) ?? .nan))
            table.labels.append(fields[4])
        }
        return table
    }

    /// scikit-learn's `adjusted_rand_score`, from the contingency table.
    static func ari(_ a: [Substring], _ b: [Substring]) -> Double {
        func pairs(_ n: Int) -> Double { Double(n) * Double(n - 1) / 2 }
        var table: [String: Int] = [:], rows: [Substring: Int] = [:], columns: [Substring: Int] = [:]
        for (u, v) in zip(a, b) {
            table["\(u)\t\(v)", default: 0] += 1
            rows[u, default: 0] += 1
            columns[v, default: 0] += 1
        }
        let index = table.values.reduce(0) { $0 + pairs($1) }
        let (sumA, sumB) = (rows.values.reduce(0) { $0 + pairs($1) }, columns.values.reduce(0) { $0 + pairs($1) })
        let expected = sumA * sumB / pairs(a.count)
        let maximum = (sumA + sumB) / 2
        return maximum == expected ? 1 : (index - expected) / (maximum - expected)
    }

    /// For each cell, the 15 nearest other cells by brute Euclidean distance on the pin and on the run, the cell itself
    /// dropped by index. Returns the mean share kept, its 5th percentile and the share of cells below 0.5.
    static func neighboursKept(_ pin: Cells, _ run: Cells) -> (mean: Double, p5: Double, below: Double) {
        func nearest(_ t: Cells, _ i: Int) -> Set<Int> {
            let order = t.x.indices.filter { $0 != i }.sorted {
                let (a, b) = (pow(t.x[$0] - t.x[i], 2) + pow(t.y[$0] - t.y[i], 2), pow(t.x[$1] - t.x[i], 2) + pow(t.y[$1] - t.y[i], 2))
                return a == b ? $0 < $1 : a < b
            }
            return Set(order.prefix(k))
        }
        let shares = pin.x.indices.map { Double(nearest(pin, $0).intersection(nearest(run, $0)).count) / Double(k) }.sorted()
        let mean = shares.reduce(0, +) / Double(max(shares.count, 1))
        let p5 = shares.isEmpty ? 0 : shares[max(0, Int((0.05 * Double(shares.count)).rounded(.up)) - 1)]
        return (mean, p5, Double(shares.filter { $0 < 0.5 }.count) / Double(max(shares.count, 1)))
    }

    /// Every leaf of a record as a dotted key, an array kept whole.
    static func flatten(_ value: ParameterValue, _ prefix: String = "") -> [String: ParameterValue] {
        guard case .dictionary(let fields) = value else { return [prefix: value] }
        return fields.reduce(into: [:]) { out, field in
            out.merge(flatten(field.value, prefix.isEmpty ? field.key : "\(prefix).\(field.key)")) { first, _ in first }
        }
    }

    /// The keys of the run's record that differ from the pin's, the nine keys of TIERB-BIO item 2 aside.
    static func recordDifferences(_ run: ParameterValue, _ pin: ParameterValue) -> [String] {
        let (a, b) = (flatten(run), flatten(pin))
        return Set(a.keys).union(b.keys).subtracting(leftOut).filter { a[$0] != b[$0] }.sorted()
    }

    /// The pin's labels matched one to one to the run's, greedily by the largest overlap first, and the cells that sit
    /// in another cluster after the match.
    static func movedCells(_ pin: [Substring], _ run: [Substring]) -> Int {
        var overlap: [String: Int] = [:]
        for (u, v) in zip(pin, run) { overlap["\(u)\t\(v)", default: 0] += 1 }
        var (usedPin, usedRun, kept) = (Set<Substring>(), Set<Substring>(), 0)
        for (key, count) in overlap.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            let parts = key.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2, !usedPin.contains(parts[0]), !usedRun.contains(parts[1]) else { continue }
            usedPin.insert(parts[0])
            usedRun.insert(parts[1])
            kept += count
        }
        return pin.count - kept
    }

    static func sizes(_ labels: [Substring]) -> String {
        Dictionary(grouping: labels, by: { $0 }).mapValues(\.count).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key):\($0.value)" }.joined(separator: " ")
    }

    static func lines(_ url: URL?) -> [Substring] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().map { $0 }
    }

    /// The verdict of TIERB-BIO item 5, after printing the byte result and the three lines of items 3 and 4.
    static func verdict(run: URL, pin: URL, record: ParameterValue, pinRecord: ParameterValue,
                        runFolder: URL?, pinFolder: URL) throws -> String {
        let (p, r) = (try cells(pin), try cells(run))
        func body(_ data: Data) -> Data { data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.index(after: $0)...] } ?? Data() }
        let tableBytes = body(try Data(contentsOf: pin)) == body(try Data(contentsOf: run))
        let genes = (lines(runFolder?.appendingPathComponent("variable_genes.tsv")), lines(pinFolder.appendingPathComponent("variable_genes.tsv")))
        let genesBytes = !genes.0.isEmpty && genes.0 == genes.1
        print("X4 tier B bytes: labels and coordinates \(tableBytes ? "equal" : "differ"), variable_genes.tsv \(genesBytes ? "equal" : "differs or is missing")")
        guard p.ids == r.ids else { return "fail: cell ids are not the pin's by bytes and in order" }
        if tableBytes { return "equal by bytes" }
        let differences = recordDifferences(record, pinRecord)
        guard differences.isEmpty else { return "fail: record keys \(differences.joined(separator: ", "))" }
        let moved = movedCells(p.labels, r.labels)
        let pinClusters = Set(p.labels).count, runClusters = Set(r.labels).count
        print("X4 tier B labels: clusters \(pinClusters) on the pin and \(runClusters) on the run; sizes pin [\(sizes(p.labels))] run [\(sizes(r.labels))]; "
              + "\(moved) cells (\(String(format: "%.1f", 100 * Double(moved) / Double(max(p.labels.count, 1))))%) in another cluster after a one-to-one match; "
              + "labels \(p.labels == r.labels ? "equal" : "not equal") by value")
        let geneIDs = (Set(genes.0.map { $0.prefix { $0 != "\t" } }), Set(genes.1.map { $0.prefix { $0 != "\t" } }))
        let (geneIn, geneOut) = (geneIDs.0.subtracting(geneIDs.1).count, geneIDs.1.subtracting(geneIDs.0).count)
        print("X4 tier B variable genes: \(geneIn) in and \(geneOut) out of the 2,000")
        let ratios = (lines(runFolder?.appendingPathComponent("pca_variance_ratio.tsv")), lines(pinFolder.appendingPathComponent("pca_variance_ratio.tsv")))
        let change = zip(ratios.0, ratios.1).prefix(30).map { a, b in
            abs((Double(a.split(separator: "\t").last ?? "") ?? .nan) - (Double(b.split(separator: "\t").last ?? "") ?? .nan))
        }.max() ?? .nan
        print("X4 tier B PCA: largest change of variance_ratio over PCs 1 to 30 is \(change)")
        let score = ari(p.labels, r.labels)
        let kept = neighboursKept(p, r)
        print("X4 tier B neighbours kept: mean \(kept.mean), 5th percentile \(kept.p5), share below 0.5 \(kept.below)")
        let (x, y) = (String(format: "%.4f", score), String(format: "%.4f", kept.mean))
        guard score >= labelBar else { return "fail: ARI \(score)" }
        guard kept.mean >= neighbourBar else { return "fail: neighbours kept \(kept.mean)" }
        if p.labels == r.labels && genesBytes { return "same meaning (labels equal, variable genes equal, neighbours kept \(y))" }
        let share = String(format: "%.1f", 100 * Double(moved) / Double(max(p.labels.count, 1)))
        return "passes by meaning, moved: clusters \(pinClusters) against \(runClusters), \(moved) cells (\(share)%) in another cluster, "
            + "\(geneIn) variable genes in and \(geneOut) out; ARI \(x), neighbours kept \(y)"
    }
}
