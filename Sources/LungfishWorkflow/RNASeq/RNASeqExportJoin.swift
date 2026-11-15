// RNASeqExportJoin.swift - One table of one route on one reference set, or a refusal (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Counts from two routes, or from two reference sets, never join in one table (`docs/formats/rnaseq-bundle.md`, One table,
// one route). The words are those of `SCR/rulings/ADJ-BULK-5.md` item 6. A set or a tool that reads Not recorded cannot be
// shown to match another result, so a join of such results is refused and one such result alone exports. No override flag.

import Foundation
import LungfishIO

public struct RNASeqExportJoin: Sendable {
    public var results: [RNASeqExportResult]
    public var route: RNASeqResultManifest.Route
    public var referenceSet: RNASeqResultManifest.ReferenceSet?
    public var unit: RNASeqResultManifest.CountEntry.Unit
    /// The default column, genes by the samples of every result in the order given.
    public var counts: RNASeqCountTable
    /// The masked column, written beside the default one and never joined to it. Nil when no result holds one.
    public var masked: RNASeqCountTable?
    public var genes: [RNASeqGeneRecord]
    public var notHost: [String]
    public var samples: [RNASeqSampleRecord]
    /// The index in `results` of the result each sample came from.
    public var sampleResult: [String: Int]

    private struct Tables {
        var gene: RNASeqResult.CountTable
        var masked: RNASeqResult.CountTable?
    }

    public static func make(_ results: [RNASeqExportResult]) throws -> RNASeqExportJoin {
        let tables = try results.map { item -> Tables in
            guard let gene = item.result.counts.first(where: { $0.entry.rows == .gene && $0.entry.column == .default }) else {
                throw RNASeqExportRefusal(
                    "\(item.label) holds no gene counts. Import salmon folders with --tx2gene, or a table of genes, and export that result.")
            }
            return Tables(gene: gene, masked: item.result.counts.first { $0.entry.rows == .gene && $0.entry.column == .masked })
        }
        let size = tables.map { $0.gene.table.sampleIDs.count }
        try refuseMixedRoutesAndSets(results, sizes: size)
        let units = Set(tables.map { $0.gene.entry.unit.rawValue })
        guard units.count == 1 else {
            throw RNASeqExportRefusal("The results count in different units (\(units.sorted().joined(separator: ", "))), so they cannot share one table.")
        }
        let first = results[0]
        let ids = tables[0].gene.table.rows.map(\.id)
        for (index, other) in tables.enumerated().dropFirst() {
            let otherIDs = Set(other.gene.table.rows.map(\.id))
            guard otherIDs == Set(ids) else {
                throw RNASeqExportRefusal(
                    "The results \(first.label) and \(results[index].label) list different genes (\(Set(ids).subtracting(otherIDs).count) only in the first, "
                        + "\(otherIDs.subtracting(ids).count) only in the second), so they were not counted against one gene table and cannot share one table.")
            }
            guard Set(results[index].manifest.notHost) == Set(first.manifest.notHost) else {
                throw RNASeqExportRefusal("The results \(first.label) and \(results[index].label) mark different features as not host, so they cannot share one table.")
            }
        }
        var owner: [String: Int] = [:]
        var sampleIDs: [String] = []
        for (index, table) in tables.enumerated() {
            for id in table.gene.table.sampleIDs {
                if let earlier = owner[id] {
                    throw RNASeqExportRefusal("The sample \(id) is in both \(results[earlier].label) and \(results[index].label). Each sample is one column of the table, so export results that hold different samples.")
                }
                owner[id] = index
                sampleIDs.append(id)
            }
        }
        // Each row of each table is found by its id through a map built once for the table, never by a scan of the table for
        // every gene, which made the time grow with the square of the gene count (3 min 21 s for 60,371 genes).
        let positions = tables.map { rowPositions($0.gene.table.rows) }
        let rows = ids.indices.map { position -> RNASeqCountTable.Row in
            RNASeqCountTable.Row(id: ids[position], counts: tables.indices.flatMap { index -> [Double] in
                let held = tables[index].gene.table.rows
                return held[positions[index][ids[position]] ?? position].counts
            })
        }
        let masked = try joinedMasked(tables, results: results, sampleIDs: sampleIDs)
        let records = results.flatMap { item in item.result.samples }
        return RNASeqExportJoin(
            results: results, route: first.manifest.route, referenceSet: first.manifest.referenceSet,
            unit: tables[0].gene.entry.unit, counts: RNASeqCountTable(sampleIDs: sampleIDs, rows: rows), masked: masked,
            genes: first.result.genes, notHost: first.manifest.notHost,
            samples: sampleIDs.map { id in records.first { $0.id == id } ?? RNASeqSampleRecord(id: id) }, sampleResult: owner)
    }

    private static func joinedMasked(_ tables: [Tables], results: [RNASeqExportResult], sampleIDs: [String]) throws -> RNASeqCountTable? {
        let held = tables.compactMap(\.masked)
        guard !held.isEmpty else { return nil }
        let ids = held[0].table.rows.map(\.id)
        guard held.count == tables.count, held.allSatisfy({ Set($0.table.rows.map(\.id)) == Set(ids) }) else {
            throw RNASeqExportRefusal("The results do not move the same features into the masked column, so their masked counts cannot share one table.")
        }
        let positions = held.map { rowPositions($0.table.rows) }
        let rows = ids.map { id in
            RNASeqCountTable.Row(id: id, counts: held.indices.flatMap { index in positions[index][id].map { held[index].table.rows[$0].counts } ?? [] })
        }
        return RNASeqCountTable(sampleIDs: sampleIDs, rows: rows)
    }

    /// The position of each row by its id, built once for a table. A gene listed twice keeps its first row, as a scan finds it.
    private static func rowPositions(_ rows: [RNASeqCountTable.Row]) -> [String: Int] {
        var positions: [String: Int] = [:]
        positions.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() where positions[row.id] == nil { positions[row.id] = index }
        return positions
    }

    private static func refuseMixedRoutesAndSets(_ results: [RNASeqExportResult], sizes: [Int]) throws {
        guard results.count > 1 else { return }
        var routes: [(route: RNASeqResultManifest.Route, samples: Int)] = []
        var sets: [(set: RNASeqResultManifest.ReferenceSet?, samples: Int)] = []
        for (item, count) in zip(results, sizes) {
            if let at = routes.firstIndex(where: { $0.route == item.manifest.route }) { routes[at].samples += count } else { routes.append((item.manifest.route, count)) }
            if let at = sets.firstIndex(where: { $0.set == item.manifest.referenceSet }) { sets[at].samples += count } else { sets.append((item.manifest.referenceSet, count)) }
        }
        if routes.count > 1 {
            let groups = routes.map { "\(RNASeqExportWords.route($0.route)) (\(RNASeqExportWords.samples($0.samples)))" }
            throw RNASeqExportRefusal(
                "These samples were counted by different routes: \(RNASeqExportWords.list(groups)). Counts from different routes differ gene by gene, "
                    + "so comparing them finds differences the samples do not have. Export samples counted by one route, or count them all again by one route.")
        }
        let unrecorded = results.filter { $0.manifest.referenceSet == nil }.map(\.label)
        if !unrecorded.isEmpty {
            throw RNASeqExportRefusal(
                "The reference set of \(RNASeqExportWords.list(unrecorded)) is Not recorded, so LGE cannot show that these results were counted against one set. "
                    + "A table joins results only when each names its reference set and all name the same one. Export each result by itself, or count the reads again with LGE against a reference set.")
        }
        if sets.count > 1 {
            let groups = sets.map { "\(RNASeqExportWords.referenceSet($0.set)) (\(RNASeqExportWords.samples($0.samples)))" }
            throw RNASeqExportRefusal(
                "These samples were counted against different reference sets: \(RNASeqExportWords.list(groups)). Counts against different reference sets name different genes "
                    + "and different gene lengths, so comparing them finds differences the samples do not have. "
                    + "Export samples counted against one reference set, or count them all again against one reference set.")
        }
        if results.contains(where: { $0.manifest.route.tool == RNASeqResultBundle.notRecordedText }) {
            throw RNASeqExportRefusal(
                "The tool that counted \(RNASeqExportWords.list(results.map(\.label))) is Not recorded, so LGE cannot show that these results came from one route. "
                    + "Export each result by itself, or count the samples again by one route.")
        }
    }
}
