// RNASeqExportTestSupport.swift - Small RNA-seq results for the export tests, made by the one writer (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

typealias RNASeqExportRoute = RNASeqResultManifest.Route

enum RNASeqExportFixture {
    static let salmonReads = RNASeqExportRoute(
        id: "salmon-reads", tool: "salmon", toolVersion: "2.11.0", settings: ["input": "reads", "mode": "selective-alignment"])
    static let starSalmon = RNASeqExportRoute(
        id: "star-salmon", tool: "salmon", toolVersion: "2.11.0", settings: ["input": "star-transcriptome-bam", "flag": "-a"])
    static let geneCounts2 = RNASeqExportRoute(id: "star-genecounts", tool: "STAR", toolVersion: "2.7.3a", settings: ["column": "2"])
    static let geneCounts3 = RNASeqExportRoute(id: "star-genecounts", tool: "STAR", toolVersion: "2.7.3a", settings: ["column": "3"])
    static let featureCounts = RNASeqExportRoute(
        id: "featurecounts", tool: "featureCounts", toolVersion: "2.1.1", settings: ["-M": "on", "-O": "off", "-s": "0", "--fraction": "off"])
    static let humanSet = RNASeqResultManifest.ReferenceSet(id: "human-lge-1", layout: .lge)

    struct Spec {
        var name: String
        var route = RNASeqExportFixture.salmonReads
        var set: RNASeqResultManifest.ReferenceSet? = RNASeqExportFixture.humanSet
        var samples: [String] = ["S1", "S2"]
        var genes = ["G1", "G2", "G3", "G4"]
        var notHost: [String] = []
        var groups: [String: String] = [:]
        var quality: RNASeqQualityTable?
        var shift = 0
        var masked = false
        /// Zero keeps the counts linear. Above zero each count is scaled by a fixed wave of this size, so DESeq2 has
        /// dispersions to fit (the not-host R run reads such a folder).
        var noise = 0.0
    }

    /// Writes one result into `analyses` with the one writer and returns its folder. The gene table is the set's own
    /// shape, with `not_host` true for the features in `notHost`. Each sample keeps a small `quant.sf`.
    static func make(_ spec: Spec, in analyses: URL) throws -> URL {
        let scratch = analyses.deletingLastPathComponent().appendingPathComponent("inputs-\(spec.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var genesText = "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\n"
        for id in spec.genes {
            genesText += "\(id)\t\(id)\tprotein_coding\tchr1\t1000\t\(spec.notHost.contains(id) ? "true" : "false")\t\t\n"
        }
        let genesURL = scratch.appendingPathComponent("genes.tsv")
        try genesText.write(to: genesURL, atomically: true, encoding: .utf8)
        var sources: [RNASeqResultWriter.SourceFile] = []
        for id in spec.samples {
            let file = scratch.appendingPathComponent("quant-\(id).sf")
            try "Name\tLength\tNumReads\nT1\t1000\t\(id.count)\n".write(to: file, atomically: true, encoding: .utf8)
            sources.append(.init(url: file, relativePath: "quant.sf", sample: id, tool: spec.route.tool))
        }
        let all = spec.genes.enumerated().map { gene, id in
            RNASeqCountTable.Row(id: id, counts: spec.samples.indices.map { sample in
                let linear = Double(10 * (gene + 1) + sample + spec.shift)
                return spec.noise == 0 ? linear : (linear * (1 + spec.noise * sin(Double(gene * 31 + sample * 17 + 3)))).rounded()
            })
        }
        // A mask moves the last gene out of the default count and into the masked column.
        let rows = spec.masked ? Array(all.dropLast()) : all
        let maskedCounts: [RNASeqResultWriter.CountInput] = spec.masked
            ? [.init(rows: .gene, column: .masked, unit: .estimated, table: RNASeqCountTable(sampleIDs: spec.samples, rows: [all[all.count - 1]]))] : []
        let request = RNASeqResultWriter.Request(
            name: spec.name, modality: .bulk, origin: .init(kind: .quantified), route: spec.route, referenceSet: spec.set,
            samples: spec.samples.map { RNASeqSampleRecord(id: $0, group: spec.groups[$0], runs: [$0]) },
            genes: spec.set == nil ? .ids(spec.genes) : .referenceSetTable(url: genesURL, keeping: spec.genes),
            counts: [.init(rows: .gene, column: .default, unit: .estimated, table: RNASeqCountTable(sampleIDs: spec.samples, rows: rows))] + maskedCounts,
            sourceFiles: sources, notHost: spec.notHost, quality: spec.quality)
        let url = analyses.appendingPathComponent("\(spec.name).lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq quantification", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
        return url
    }

    static func join(_ urls: [URL]) throws -> RNASeqExportJoin {
        try RNASeqExportJoin.make(try RNASeqExportReader.read(urls))
    }

    /// A sample table of one row a sample, with the given columns, for the design check.
    static func table(_ columns: [String], _ rows: [[String]]) -> RNASeqExportSampleTable {
        RNASeqExportSampleTable(columns: columns, rows: rows)
    }
}

class RNASeqExportTestCase: XCTestCase {
    var root: URL!
    var analyses: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-export-\(UUID().uuidString)", isDirectory: true)
        analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func make(_ spec: RNASeqExportFixture.Spec) throws -> URL { try RNASeqExportFixture.make(spec, in: analyses) }
}
