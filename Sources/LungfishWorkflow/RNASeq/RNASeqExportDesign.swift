// RNASeqExportDesign.swift - The settings of an export and the design check before a batch step (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `SCR/rulings/ADJ-BULK.md:104-107`. When a batch is nested in or equal to a level of a design factor, or holds only whole
// levels of it so that `~ batch + design` loses full rank (C7's batch B holds exactly days 3 and 10), ComBat-seq and sva
// are refused in words that name the batch, the factor and its levels. The same check runs in each template before its batch step.

import Foundation

/// One row a sample with named columns, as `samples.tsv` of the export holds them.
public struct RNASeqExportSampleTable: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    func values(of column: String) -> [String]? {
        columns.firstIndex(of: column).map { index in rows.map { index < $0.count ? $0[index] : "" } }
    }
}

public struct RNASeqExportSettings: Equatable, Sendable {
    public struct Contrast: Equatable, Sendable {
        public var factor: String
        public var numerator: String
        public var denominator: String

        public init(factor: String, numerator: String, denominator: String) {
            self.factor = factor
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    public enum BatchCorrection: String, Sendable { case none, combatSeq = "combat-seq", sva }

    /// Columns of `samples.tsv` that enter the model. The last is the factor the contrasts test.
    public var design: [String]
    public var contrasts: [Contrast]
    public var padjCutoff: Double
    /// A bar on the MLE log2 fold change, none by default.
    public var lfcBar: Double?
    public var batch: String?
    public var batchCorrection: BatchCorrection

    public init(
        design: [String] = [], contrasts: [Contrast] = [], padjCutoff: Double = 0.05, lfcBar: Double? = nil, batch: String? = nil,
        batchCorrection: BatchCorrection = .none
    ) {
        self.design = design
        self.contrasts = contrasts
        self.padjCutoff = padjCutoff
        self.lfcBar = lfcBar
        self.batch = batch
        self.batchCorrection = batchCorrection
    }
}

public enum RNASeqExportDesignCheck {
    public static func check(_ settings: RNASeqExportSettings, samples: RNASeqExportSampleTable) throws {
        for term in settings.design {
            guard let values = samples.values(of: term) else {
                throw RNASeqExportRefusal(
                    "The design names the column \(term), which samples.tsv does not hold. Its columns are \(samples.columns.joined(separator: ", ")).")
            }
            if let at = values.firstIndex(of: "") {
                throw RNASeqExportRefusal("The design column \(term) has no value for the sample \(samples.rows[at].first ?? ""). Fill it in the sample sheet or leave the column out of the design.")
            }
        }
        let step = settings.batchCorrection
        guard step != .none else {
            if settings.batch != nil {
                throw RNASeqExportRefusal("--batch names the column a batch step corrects, and --batch-correction is none, so no step would run. Pass --batch-correction combat-seq or sva, or name the column in --design to model it.")
            }
            return
        }
        guard let batch = settings.batch else {
            throw RNASeqExportRefusal("--batch-correction \(step.rawValue) needs --batch, the column of samples.tsv that names each sample's batch.")
        }
        guard let batches = samples.values(of: batch), !batches.contains("") else {
            throw RNASeqExportRefusal("The batch column \(batch) is missing from samples.tsv or has an empty cell. Its columns are \(samples.columns.joined(separator: ", ")).")
        }
        guard !settings.design.isEmpty else {
            throw RNASeqExportRefusal("--batch-correction \(step.rawValue) needs --design, so the correction can leave the tested difference alone.")
        }
        let model = "~ \(batch) + \(settings.design.joined(separator: " + "))"
        let batchLevels = Array(Set(batches)).sorted()
        guard batchLevels.count > 1 else {
            throw RNASeqExportRefusal("The batch column \(batch) holds one value for every sample, so there is no batch to correct. Pass --batch-correction none.")
        }
        for factor in settings.design where factor != batch {
            let levels = samples.values(of: factor) ?? []
            var findings: [String] = []
            for level in batchLevels {
                let inside = Array(Set(zip(batches, levels).filter { $0.0 == level }.map(\.1))).sorted()
                let whole = inside.filter { member in zip(batches, levels).filter { $0.1 == member }.allSatisfy { $0.0 == level } }
                if inside.count == 1 {
                    findings.append("The batch \(level) holds only samples of the level \(inside[0]) of \(factor)")
                } else if whole == inside {
                    findings.append("The batch \(level) holds exactly the levels \(RNASeqExportWords.list(inside)) of \(factor) and every sample of them")
                }
            }
            if !findings.isEmpty {
                throw RNASeqExportRefusal(
                    "\(step.rawValue) cannot run on the batch column \(batch) with the design \(model). \(findings.joined(separator: ". ")). "
                        + "So \(model) loses full rank, and the batch cannot be told apart from those levels of \(factor). "
                        + "Use a batch that crosses the levels of \(factor), or pass --batch-correction none.")
            }
            if rank(columns: [batches, levels]) < dummyCount([batches, levels]) {
                throw RNASeqExportRefusal(
                    "\(step.rawValue) cannot run on the batch column \(batch) with the design \(model), because \(model) loses full rank. "
                        + "The batch and \(factor) overlap so that no model can separate them. Use a batch that crosses the levels of \(factor), or pass --batch-correction none.")
            }
        }
    }

    private static func dummyCount(_ factors: [[String]]) -> Int { 1 + factors.reduce(0) { $0 + Set($1).count - 1 } }

    /// The rank of the model matrix of an intercept and the treatment dummies of each factor, by elimination.
    private static func rank(columns factors: [[String]]) -> Int {
        let rows = factors[0].count
        var columns: [[Double]] = [Array(repeating: 1, count: rows)]
        for factor in factors {
            for level in Array(Set(factor)).sorted().dropFirst() { columns.append(factor.map { $0 == level ? 1 : 0 }) }
        }
        var rank = 0
        for column in columns.indices {
            guard let pivot = (rank..<rows).max(by: { abs(columns[column][$0]) < abs(columns[column][$1]) }), abs(columns[column][pivot]) > 1e-9 else { continue }
            for other in columns.indices { columns[other].swapAt(rank, pivot) }
            for next in (column + 1)..<max(column + 1, columns.count) {
                let factor = columns[next][rank] / columns[column][rank]
                for row in rank..<rows { columns[next][row] -= factor * columns[column][row] }
            }
            rank += 1
        }
        return rank
    }
}
