// SalmonQuantFolderReaderTests.swift - salmon folders read as given (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class SalmonQuantFolderReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "salmon-folder-reader") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// NumReads by transcript in file order, read by the test itself.
    private func numReads(_ run: String) throws -> [(String, Double)] {
        let text = try String(contentsOf: RNASeqFixtures.salmonRun(run).appendingPathComponent("quant.sf"), encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { line in
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            return (String(cells[0]), Double(cells[4]) ?? .nan)
        }
    }

    /// Each run of three transcripts is one gene, and an ERCC maps to itself.
    private func writeTx2Gene(_ ids: [String]) throws -> (URL, [String: String]) {
        var map: [String: String] = [:]
        var lines = ["transcript_id\tgene_id\tgene_name"]
        for (index, id) in ids.enumerated() {
            let gene = id.hasPrefix("ERCC-") ? id : "G\(index / 3)"
            map[id] = gene
            lines.append("\(id)\t\(gene)\tname\(index)")
        }
        let url = root.appendingPathComponent("tx2gene.tsv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return (url, map)
    }

    private func copyRun(_ run: String, leaving left: String? = nil) throws -> URL {
        let copy = root.appendingPathComponent(run, isDirectory: true)
        try FileManager.default.copyItem(at: RNASeqFixtures.salmonRun(run), to: copy)
        if let left { try FileManager.default.removeItem(at: copy.appendingPathComponent(left)) }
        return copy
    }

    func testGeneSumsOnSalmonC1EqualNumReadsSummedByGene() throws {
        let runs = RNASeqFixtures.salmonRunIDs
        let folders = try runs.map { try SalmonQuantFolderReader.read(folder: RNASeqFixtures.salmonRun($0)) }
        let columns = try runs.map(numReads)
        let (tx2geneURL, map) = try writeTx2Gene(columns[0].map(\.0))
        let genes = try SalmonQuantFolderReader.geneCounts(folders, tx2gene: try SalmonTx2Gene.read(tx2geneURL))

        var expected: [String: [Double]] = [:]
        for (sample, column) in columns.enumerated() {
            for (id, reads) in column {
                let gene = try XCTUnwrap(map[id])
                expected[gene, default: Array(repeating: 0, count: runs.count)][sample] += reads
            }
        }
        XCTAssertEqual(genes.sampleIDs, runs)
        XCTAssertEqual(genes.rows.count, expected.count)
        XCTAssertEqual(Set(genes.rows.map(\.id)), Set(expected.keys))
        for row in genes.rows {
            let want = try XCTUnwrap(expected[row.id])
            for (got, sum) in zip(row.counts, want) { XCTAssertEqual(got, sum, accuracy: 1e-9, row.id) }
        }
        XCTAssertGreaterThan(genes.rows.reduce(0) { $0 + $1.counts[0] }, 0, "the fixture holds reads")
    }

    func testTranscriptCountsAreNumReadsAsGiven() throws {
        let runs = RNASeqFixtures.salmonRunIDs
        let folders = try runs.map { try SalmonQuantFolderReader.read(folder: RNASeqFixtures.salmonRun($0)) }
        let table = try SalmonQuantFolderReader.transcriptCounts(folders)
        let first = try numReads(runs[0])
        XCTAssertEqual(table.sampleIDs, runs)
        XCTAssertEqual(table.rows.count, 395)
        XCTAssertEqual(table.rows.map(\.id), first.map(\.0))
        XCTAssertEqual(table.rows.map { $0.counts[0] }, first.map(\.1))
    }

    // MARK: - quality

    func testQualityNumbersAreSalmonsOwn() throws {
        let folder = try SalmonQuantFolderReader.read(folder: RNASeqFixtures.salmonRun("SRR896663"))
        let quality = folder.quality
        XCTAssertEqual(folder.sample, "SRR896663")
        XCTAssertEqual(quality.salmonVersion, "2.11.0")
        XCTAssertEqual(quality.numProcessed, 5_728_703)
        XCTAssertEqual(quality.numMapped, 4_829_449)
        XCTAssertEqual(quality.percentMapped, 84.30265978180401)
        XCTAssertEqual(quality.libraryType, "IU")
        XCTAssertEqual(quality.expectedFormat, "IU")
        XCTAssertEqual(quality.libTypeOption, "A")
        XCTAssertEqual(quality.seqBiasCorrect, false)
        XCTAssertEqual(quality.gcBiasCorrect, false)
        XCTAssertEqual(quality.posBiasCorrect, false)
        XCTAssertEqual(quality.indexHashes["index_seq_hash"], "50b7f62d463e1405b746f0b0eb1b46a4a74ee1e4fb4077cc04fc58a24ab09a36")
        XCTAssertEqual(quality.indexHashes["index_decoy_name_hash"], "01c56669eed27669376eefee85477e65d513bd953a64fd8ee76277dbdf8f47d4")
        XCTAssertEqual(folder.keptFiles, RNASeqFixtures.salmonFiles)
    }

    func testTheYeastFolderKeepsQuantGenesAsGiven() throws {
        let url = RNASeqFixtures.root.appendingPathComponent("nfcore-rnaseq-yeast/salmon/WT_REP1", isDirectory: true)
        let folder = try SalmonQuantFolderReader.read(folder: url)
        XCTAssertEqual(folder.sample, "WT_REP1")
        XCTAssertEqual(folder.quality.salmonVersion, "1.10.1")
        XCTAssertEqual(folder.quality.libraryType, "ISR")
        XCTAssertEqual(folder.quality.numProcessed, 99_225)
        XCTAssertEqual(folder.keptFiles, RNASeqFixtures.salmonFiles + ["quant.genes.sf"])
        let files = SalmonQuantFolderReader.sourceFiles([folder])
        XCTAssertEqual(files.map(\.relativePath), folder.keptFiles)
        XCTAssertEqual(Set(files.map { $0.sample ?? "" }), ["WT_REP1"])
        XCTAssertEqual(Set(files.map(\.tool)), ["salmon"])
    }

    func testTheQualityTableHasOneRowASample() throws {
        let folders = try RNASeqFixtures.salmonRunIDs.map { try SalmonQuantFolderReader.read(folder: RNASeqFixtures.salmonRun($0)) }
        let table = SalmonQuantFolderReader.qualityTable(folders)
        XCTAssertEqual(table.columns, SalmonQuantFolderReader.qualityColumns)
        XCTAssertEqual(table.rows.map(\.sample), RNASeqFixtures.salmonRunIDs)
        let first = try XCTUnwrap(table.rows.first)
        func value(_ column: String) -> String? { table.columns.firstIndex(of: column).flatMap { first.values[$0] } }
        XCTAssertEqual(value("num_processed"), "5728703")
        XCTAssertEqual(value("percent_mapped"), "84.30265978180401")
        XCTAssertEqual(value("library_type"), "IU")
        XCTAssertEqual(value("salmon_version"), "2.11.0")
        XCTAssertEqual(value("seq_bias_correct"), "false")
        XCTAssertEqual(value("index_seq_hash"), "50b7f62d463e1405b746f0b0eb1b46a4a74ee1e4fb4077cc04fc58a24ab09a36")
        let lines = String(decoding: try table.tsvData(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "a header and one row a sample")
        XCTAssertEqual(lines.first?.split(separator: "\t").first, "sample_id")
    }

    // MARK: - refusals

    func testAFolderWithoutItsLibraryFormatIsRefused() throws {
        let copy = try copyRun("SRR896663", leaving: "lib_format_counts.json")
        XCTAssertThrowsError(try SalmonQuantFolderReader.read(folder: copy)) { error in
            XCTAssertEqual(error as? RNASeqImportError, .missingFile(folder: "SRR896663", file: "lib_format_counts.json"))
            XCTAssertTrue(error.localizedDescription.contains("lib_format_counts.json"), error.localizedDescription)
        }
    }

    func testFoldersOnDifferentTranscriptsAreRefused() throws {
        let c1 = try SalmonQuantFolderReader.read(folder: RNASeqFixtures.salmonRun("SRR896663"))
        let yeast = try SalmonQuantFolderReader.read(
            folder: RNASeqFixtures.root.appendingPathComponent("nfcore-rnaseq-yeast/salmon/WT_REP1", isDirectory: true))
        XCTAssertThrowsError(try SalmonQuantFolderReader.transcriptCounts([c1, yeast])) { error in
            XCTAssertEqual(error as? RNASeqImportError, .transcriptSetsDiffer(first: "SRR896663", other: "WT_REP1"))
        }
    }

    /// Review SF3 (UX 1): a table with no header line says which first line to add.
    func testATx2GeneWithoutAHeaderSaysWhatToAdd() throws {
        let url = root.appendingPathComponent("tx2gene.tsv")
        try "T1\tG1\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SalmonTx2Gene.read(url)) { error in
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("transcript_id") && words.contains("first line"), words)
            XCTAssertTrue(words.contains("Add a first line with those two names, separated by a tab"), words)
        }
    }

    func testATranscriptWithoutAGeneIsRefusedInWords() throws {
        let folder = try SalmonQuantFolderReader.read(folder: RNASeqFixtures.salmonRun("SRR896663"))
        let ids = try numReads("SRR896663").map(\.0)
        let (url, _) = try writeTx2Gene(Array(ids.dropFirst()))
        XCTAssertThrowsError(try SalmonQuantFolderReader.geneCounts([folder], tx2gene: try SalmonTx2Gene.read(url))) { error in
            XCTAssertEqual(error as? RNASeqImportError, .transcriptsWithoutGene(count: 1, examples: [ids[0]]))
            XCTAssertTrue(error.localizedDescription.contains(ids[0]), error.localizedDescription)
        }
    }
}
