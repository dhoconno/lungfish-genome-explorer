// RNASeqExportFolderTests.swift - The export folder, its record and its refusals (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class RNASeqExportFolderTests: RNASeqExportTestCase {
    typealias Fix = RNASeqExportFixture
    private let recordName = ".lungfish-provenance.json"

    private var base: RNASeqExportSettings {
        RNASeqExportSettings(design: ["group"], contrasts: [.init(factor: "group", numerator: "TB", denominator: "HIV")])
    }

    @discardableResult
    private func export(
        _ results: [URL], sheet: URL? = nil, settings: RNASeqExportSettings? = nil, name: String = "out", checkpoint: (() throws -> Void)? = nil
    ) throws -> URL {
        let out = root.appendingPathComponent(name, isDirectory: true)
        try RNASeqExport.run(
            results: results, sheet: sheet, settings: settings ?? base, output: out, argv: ["lungfish-cli", "rnaseq", "export"], checkpoint: checkpoint)
        return out
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func sheet(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("sheet.tsv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTheFolderHoldsTheFilesAndTheCountsAreGenesBySamples() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        let out = try export([a])
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, [recordName, "counts.tsv", "deseq2.R", "edger-limma-dream.R", "genes.tsv", "samples.tsv"])
        let counts = try lines(out.appendingPathComponent("counts.tsv"))
        XCTAssertEqual(counts.first, "gene_id\tS1\tS2")
        XCTAssertEqual(counts[1], "G1\t10\t11")
    }

    func testTheMaskedColumnComesBesideTheDefaultAndIsNeverJoinedToIt() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"], masked: true))
        let out = try export([a])
        XCTAssertEqual(try lines(out.appendingPathComponent("counts.tsv")).map { $0.prefix { $0 != "\t" } }, ["gene_id", "G1", "G2", "G3"])
        XCTAssertEqual(try lines(out.appendingPathComponent("counts.masked.tsv")).map { $0.prefix { $0 != "\t" } }, ["gene_id", "G4"])
    }

    func testGenesTsvFlagsTheNotHostIdsAndTheirRowsStayInTheCountTable() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], notHost: ["G4"], groups: ["S1": "TB", "S2": "HIV"]))
        let out = try export([a])
        let genes = try lines(out.appendingPathComponent("genes.tsv"))
        XCTAssertEqual(genes.first, "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable")
        XCTAssertTrue(genes.contains { $0.hasPrefix("G4\t") && $0.contains("\ttrue\t") })
        XCTAssertTrue(genes.contains { $0.hasPrefix("G1\t") && $0.contains("\tfalse\t") })
        XCTAssertTrue(try lines(out.appendingPathComponent("counts.tsv")).contains { $0.hasPrefix("G4\t") })
    }

    func testSamplesTsvCarriesTheSheetColumnsRouteAndSetAndReopensAsASheet() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        let sheetURL = try sheet("sample\tday\tbatch\nS1\tD3\tA\nS2\tD5\tB\n")
        let out = try export([a], sheet: sheetURL)
        let rows = try lines(out.appendingPathComponent("samples.tsv")).map { $0.components(separatedBy: "\t") }
        let header = try XCTUnwrap(rows.first)
        for column in ["sample_id", "group", "day", "batch", "route", "reference_set"] { XCTAssertTrue(header.contains(column), "\(header)") }
        let first = Dictionary(uniqueKeysWithValues: zip(header, rows[1]))
        XCTAssertEqual(first["day"], "D3")
        XCTAssertEqual(first["route"], RNASeqExportWords.route(Fix.salmonReads))
        XCTAssertEqual(first["reference_set"], RNASeqExportWords.referenceSet(Fix.humanSet))
        // Reopened as a sheet, the same ids match, and a stale route column never decides the next export.
        let reopened = try RNASeqSampleSheet.read(out.appendingPathComponent("samples.tsv"))
        XCTAssertEqual(reopened.rows.map(\.sample), ["S1", "S2"])
        XCTAssertEqual(reopened.rows.map(\.group), ["TB", "HIV"])
        let again = try export([a], sheet: out.appendingPathComponent("samples.tsv"), name: "again")
        XCTAssertEqual(try lines(again.appendingPathComponent("samples.tsv")), try lines(out.appendingPathComponent("samples.tsv")))
    }

    func testASheetThatNamesOtherSamplesIsRefusedWithBothSidesListed() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        XCTAssertThrowsError(try export([a], sheet: try sheet("sample\tday\nS1\tD3\nS9\tD5\n"))) {
            let words = $0.localizedDescription
            XCTAssertTrue(words.contains("Only in the results: S2") && words.contains("Only in the sheet: S9"), words)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("out").path))
    }

    func testTheRecordNamesTheCutoffAlphaAndTheBar() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        for (cutoff, bar) in [(0.05, nil), (0.1, 1.4)] as [(Double, Double?)] {
            var settings = base
            settings.padjCutoff = cutoff
            settings.lfcBar = bar
            let out = try export([a], settings: settings, name: "out-\(cutoff)")
            let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
            let resolved = record.options.resolvedDefaults
            XCTAssertEqual(resolved["padjCutoff"], .string("\(cutoff)"))
            XCTAssertEqual(resolved["alpha"], .string("\(cutoff)"))
            XCTAssertEqual(resolved["lfcBar"], .string(bar.map { "\($0)" } ?? "none"))
            XCTAssertEqual(resolved["batchCorrection"], .string("none"))
            XCTAssertNotNil(resolved["results"])
        }
    }

    func testAnExistingFolderIsNeverOverwrittenAndAMixWritesNothing() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        let c = try make(.init(name: "c", route: Fix.starSalmon, samples: ["U1", "U2"]))
        let taken = root.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        XCTAssertThrowsError(try export([a], name: "taken")) { XCTAssertTrue($0.localizedDescription.contains("already exists"), $0.localizedDescription) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: taken.path), [])
        XCTAssertThrowsError(try export([a, c]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") || $0 == "out" }, [])
    }

    func testACancelLeavesNoStageAndNoFolder() throws {
        let a = try make(.init(name: "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        XCTAssertThrowsError(try export([a], checkpoint: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") || $0 == "out" }
        XCTAssertEqual(left, [], "a cancelled export leaves no stage and no folder")
    }
}
