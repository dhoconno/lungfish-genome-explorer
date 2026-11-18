// RNASeqQualitySummary+Correlation.swift - The sample correlation table of a bulk result (Phase 5.4 lane RS-BULK-VIEW M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Samples by samples, on the default count table of host genes only and never on TPM (program plan, Quality). The
// measure and the transform are constants here, so the leaf's output and the app's caption name the same ones.

import Foundation
import LungfishIO

public struct RNASeqSampleCorrelation: Equatable, Sendable {
    public static let measure = "Pearson r"
    public static let transform = "log2(CPM + 1)"
    /// The genes and the CPM the measure runs on. A gene of 0 in every sample adds only a point at the origin.
    public static let genesRule = "host genes of the default count table with a count above 0 in at least one sample, "
        + "with CPM on each sample's sum over host genes"

    public var name: String
    public var countTable: String
    public var samples: [String]
    /// The host genes the measure ran on.
    public var geneCount: Int
    /// Samples by samples, symmetric, with 1 on the diagonal. Nil where a sample has no host count or the same value
    /// on every gene, so that r is not defined.
    public var values: [[Double?]]

    public static func read(resultAt url: URL) throws -> RNASeqSampleCorrelation {
        try RNASeqSampleCorrelation(result: try RNASeqQualitySummary.loadVerified(url), label: url.lastPathComponent)
    }

    public init(result: RNASeqResult, label: String) throws {
        let table = try RNASeqQualitySummary.defaultCountTable(of: result, label: label)
        let notHost = Set(result.manifest.notHost)
        let width = table.table.sampleIDs.count
        let host = table.table.rows.filter { row in
            !notHost.contains(row.id) && row.counts.count == width && row.counts.contains { $0 > 0 }
        }
        let logCPM: [[Double]?] = (0..<width).map { sample in
            let total = host.reduce(0) { $0 + $1.counts[sample] }
            guard total > 0 else { return nil }
            return host.map { log2($0.counts[sample] / total * 1_000_000 + 1) }
        }
        var values = [[Double?]](repeating: [Double?](repeating: nil, count: width), count: width)
        for i in 0..<width {
            guard let x = logCPM[i], Self.spread(x) > 0 else { continue }
            values[i][i] = 1
            for j in (i + 1)..<width {
                guard let y = logCPM[j] else { continue }
                let r = Self.pearson(x, y)
                values[i][j] = r
                values[j][i] = r
            }
        }
        name = result.manifest.name
        countTable = table.entry.path
        samples = table.table.sampleIDs
        geneCount = host.count
        self.values = values
    }

    /// The sum of squares about the mean.
    static func spread(_ x: [Double]) -> Double {
        let mean = x.reduce(0, +) / Double(x.count)
        return x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    }

    /// Pearson's r in two passes, nil when either side has the same value on every gene.
    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, !x.isEmpty else { return nil }
        let mx = x.reduce(0, +) / Double(x.count)
        let my = y.reduce(0, +) / Double(y.count)
        var sxy = 0.0
        var sxx = 0.0
        var syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// The line the text form prints before the table, which names the measure and the transform.
    public var caption: String {
        "Sample correlation of \(name): \(Self.measure) of \(Self.transform) over \(geneCount) host genes of \(countTable) "
            + "with a count above 0 in a sample."
    }

    public func document() -> RNASeqQualityDocument {
        let rows = samples.enumerated().map { i, sample in
            [sample] + values[i].map { $0.map(RNASeqQualitySummary.plainDigits) ?? RNASeqQualitySummary.notRecordedText }
        }
        return RNASeqQualityDocument(
            result: name, table: "correlation",
            facts: [
                "countTable": countTable, "measure": Self.measure, "transform": Self.transform, "genes": Self.genesRule,
                "geneCount": String(geneCount),
            ],
            columns: ["sample_id"] + samples, rows: rows)
    }
}
