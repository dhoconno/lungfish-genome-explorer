// RNASeqSingleCellFixtures.swift - Single-cell results that the one writer makes from the pbmc_1k_v3 fixtures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each result is what `lungfish-cli import rnaseq` writes: `SingleCellFolderReader` reads the fixture folder and
// `RNASeqResultWriter` writes the result. The not-host tables are built as `SingleCellNotHostTests` builds them, from
// SAM text, so no test here needs samtools.

import AppKit
import Foundation
import LungfishIO
import LungfishTestSupport
import SQLite3
import XCTest
@testable import LungfishWorkflow

enum RNASeqSingleCellFixtures {
    enum Fixture: String, CaseIterable {
        case cellRanger = "cellranger-pbmc_1k_v3/outs"
        case starsolo = "starsolo-pbmc_1k_v3"
    }

    /// The extra of a not-host pass: a virus, a bacterium with its rRNA mask, or one with no mask, whose calls hold null
    /// p and q and the words that say why.
    enum NotHost {
        case virus, bacterium, unmaskedBacterium
    }

    /// Sets the `meta` schema of a copy of `cells.sqlite`, so a test can stand for a file of a newer LGE.
    static func setSchema(_ version: Int, of url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE meta SET value = '\(version)' WHERE key = 'schema_version'", nil, nil, nil), SQLITE_OK)
    }

    static let virus = SingleCellNotHostExtra(name: "sars-cov-2", kind: .virus, records: ["NC_045512.2"], mask: nil)
    static let mask = SingleCellNotHostExtra.Mask(
        name: "mtb-erdman-rrna", file: "mtb-erdman.mask.gtf", sha256: String(repeating: "a", count: 64), organism: "Mtb Erdman",
        intervals: [.init(record: "KK339487.1", start: 1001, end: 2000, geneID: "Q643_01372")])
    static let mtb = SingleCellNotHostExtra(name: "mtb-erdman", kind: .bacterium, records: ["KK339487.1", "KK339488.1"], mask: mask)

    /// A 16-base barcode whose byte order is the order of `value`.
    static func barcode(_ value: Int) -> String {
        String((0..<16).reversed().map { Array("ACGT")[(value >> (2 * $0)) & 3] })
    }

    /// One SAM line with the tags STARsolo writes.
    static func line(_ cb: String, _ ub: String, record: String, pos: Int, nm: Int = 0) -> String {
        ["r\(cb)\(ub)\(pos)", "0", record, String(pos), "255", "50M", "*", "0", "0", "*", "*", "NH:i:1", "nM:i:\(nm)", "CB:Z:\(cb)", "UB:Z:\(ub)"]
            .joined(separator: "\t")
    }

    /// Writes the result of `fixture` into `root/Analyses`, with the not-host tables of `notHost` when one is named.
    static func write(_ fixture: Fixture, into root: URL, notHost: NotHost? = nil) throws -> URL {
        let folder = try SingleCellFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent(fixture.rawValue, isDirectory: true))
        var request = try SingleCellFolderReader.request([folder], name: "pbmc", samples: [.init(id: folder.sample)], genomes: [])
        if let notHost {
            let cells = try MatrixMarketReader.textLines(of: folder.url.appendingPathComponent(folder.barcodes))
            // The raw list is the cells and 50,000 more barcodes at 1 UMI, which puts the cells first and a pool behind.
            let extraBarcodes = (0..<50_000).map { barcode($0) }
            let text = (cells + extraBarcodes).joined(separator: "\n") + "\n"
            let raw = SingleCellRawMatrix(
                barcodes: SingleCellBarcodeTable(data: Data(text.utf8)), totals: cells.map { _ in 900 } + extraBarcodes.map { _ in 1 })
            let extra: SingleCellNotHostExtra
            let lines: [String]
            let records: [SingleCellNotHostRecord]
            switch notHost {
            case .virus:
                extra = virus
                // Ten UMIs of the first cell, eight at nM 0 or 1, and one of the second cell.
                lines = (1...10).map { line(cells[0], "U\($0)", record: "NC_045512.2", pos: 100, nm: $0 <= 8 ? 1 : 4) }
                    + [line(cells[1], "U1", record: "NC_045512.2", pos: 100)]
                records = [.init(name: "NC_045512.2", length: 29903)]
            case .bacterium, .unmaskedBacterium:
                extra = notHost == .bacterium ? mtb : SingleCellNotHostExtra(name: "mtb-erdman", kind: .bacterium, records: ["KK339487.1", "KK339488.1"], mask: nil)
                // Six UMIs of the first cell lie outside the mask (default) and three inside it (masked).
                lines = (1...6).map { line(cells[0], "O\($0)", record: "KK339487.1", pos: 3000) }
                    + (1...3).map { line(cells[0], "M\($0)", record: "KK339487.1", pos: 1001) }
                records = [.init(name: "KK339487.1", length: 10_000), .init(name: "KK339488.1", length: 10_000)]
            }
            var counter = SingleCellNotHostCounter(extras: [extra])
            try counter.add(samText: lines.joined(separator: "\n") + "\n")
            let sample = SingleCellNotHostPass.sample(
                folder.sample, cells: cells, raw: raw, pool: SingleCellAmbientPool(raw), tallies: counter.tallies(), extras: [extra])
            request.notHostCells = SingleCellNotHostResult(extras: [extra], records: records, samples: [sample])
        }
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(
            request, to: analyses.appendingPathComponent("pbmc-\(fixture == .cellRanger ? "cellranger" : "starsolo").lungfishrnaseq"),
            envelope: ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test"))
    }

    /// The sha256 and size of every file under `folder`, and each folder, by path inside it.
    static func snapshot(_ folder: URL) throws -> [String: String] {
        var items: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys))
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            items[relative] = values.isDirectory == true ? "directory" : "\(try RNASeqResultBundle.sha256Hex(fileAt: url)) \(values.fileSize ?? -1)"
        }
        return items
    }

    @MainActor
    static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    /// The text of every field that carries an accessibility id.
    @MainActor
    static func texts(in view: NSView) -> [String: String] {
        var found: [String: String] = [:]
        for case let field as NSTextField in allSubviews(of: view) {
            let id = field.accessibilityIdentifier()
            if !id.isEmpty { found[id] = field.stringValue }
        }
        return found
    }
}
