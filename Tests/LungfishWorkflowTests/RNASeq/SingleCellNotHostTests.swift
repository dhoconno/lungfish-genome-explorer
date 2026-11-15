// SingleCellNotHostTests.swift - The not-host count, the ambient pool and the flag of a single-cell import (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The rules are gate GN's (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:94`) with ADJ-SC-3 items 1 to 4, and the
// truth is `scripts/repro/rnaseq/gse183579/virus.py` and `scripts/repro/rnaseq/gse296788/mtb.py`. The parser takes SAM
// text, so no test here needs samtools. The four pool cases carry the sizes the two studies measured.

import SQLite3
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class SingleCellNotHostTests: XCTestCase {
    static let virus = SingleCellNotHostExtra(name: "sars-cov-2", kind: .virus, records: ["NC_045512.2"], mask: nil)
    static let mask = SingleCellNotHostExtra.Mask(
        name: "mtb-erdman-rrna", file: "mtb-erdman.mask.gtf", sha256: String(repeating: "a", count: 64), organism: "Mtb Erdman",
        intervals: [.init(record: "KK339487.1", start: 1001, end: 2000, geneID: "Q643_01372")])
    static let mtb = SingleCellNotHostExtra(name: "mtb-erdman", kind: .bacterium, records: ["KK339487.1", "KK339488.1"], mask: mask)

    /// One SAM line with the tags STARsolo writes.
    func line(_ cb: String, _ ub: String, record: String = "NC_045512.2", pos: Int = 100, cigar: String = "50M",
              flag: Int = 0, nh: Int? = 1, nm: Int = 0) -> String {
        var fields = ["r\(cb)\(ub)\(pos)", String(flag), record, String(pos), "255", cigar, "*", "0", "0", "*", "*"]
        if let nh { fields.append("NH:i:\(nh)") }
        fields += ["nM:i:\(nm)", "CB:Z:\(cb)", "UB:Z:\(ub)"]
        return fields.joined(separator: "\t")
    }

    func count(_ lines: [String], extras: [SingleCellNotHostExtra] = [virus]) throws -> (SingleCellNotHostCounter, [String: SingleCellNotHostTally]) {
        var counter = SingleCellNotHostCounter(extras: extras)
        try counter.add(samText: lines.joined(separator: "\n") + "\n")
        return (counter, counter.tallies())
    }

    func counts(_ umis: Int, _ masked: Int = 0, _ nm01: Int = 0, _ maskedNM01: Int = 0) -> SingleCellNotHostCounts {
        SingleCellNotHostCounts(umis: umis, maskedUMIs: masked, umisNM01: nm01, maskedUMIsNM01: maskedNM01)
    }

    func testAUMIIsAUniquePairOfNH1PrimaryAlignmentsWithBothTags() throws {
        let (counter, tallies) = try count([
            line("AAAC", "U1"), line("AAAC", "U1", pos: 300), line("AAAC", "U2", nm: 3),
            line("AAAC", "U3", nh: 2), line("AAAC", "U4", flag: 256), line("AAAC", "U5", flag: 2048), line("AAAC", "U6", flag: 4),
            line("-", "U7"), line("AAAC", "-"), line("CCCG", "U1", flag: 16),
        ])
        XCTAssertEqual(tallies["AAAC"]?.genome, [counts(2, 0, 1, 0)])
        XCTAssertEqual(tallies["AAAC"]?.records, [counts(2, 0, 1, 0)])
        XCTAssertEqual(tallies["CCCG"]?.genome, [counts(1, 0, 1, 0)])
        XCTAssertNil(tallies["-"])
        XCTAssertEqual(counter.multimapped, 1)
        XCTAssertEqual(counter.withoutBarcode, 2)
    }

    func testAPairIsDefaultWhenAnyAlignmentLiesOutsideTheMask() throws {
        let (_, tallies) = try count([
            // U1 lies wholly in the mask, U2 has one alignment outside, U3 overlaps the mask's last base by 1 base.
            line("AAAC", "U1", record: "KK339487.1", pos: 1001, cigar: "50M"),
            line("AAAC", "U2", record: "KK339487.1", pos: 1500, cigar: "50M", nm: 2),
            line("AAAC", "U2", record: "KK339487.1", pos: 2100, cigar: "50M", nm: 2),
            line("AAAC", "U3", record: "KK339487.1", pos: 2000, cigar: "50M", nm: 1),
            // The span counts a skip, so 900 + 10 + 200N + 10 ends at 1119 and reaches the mask.
            line("AAAC", "U4", record: "KK339487.1", pos: 900, cigar: "10M200N10M", nm: 5),
            line("AAAC", "U5", record: "KK339487.1", pos: 900, cigar: "5S50M", nm: 0),
        ], extras: [Self.mtb])
        // Default U2 (outside at 2100) and U5 (900-949), masked U1, U3, U4. nM 0 or 1: U5 default, U1 and U3 masked.
        XCTAssertEqual(tallies["AAAC"]?.genome, [counts(2, 3, 1, 2)])
    }

    func testAGenomeFigureCountsAPairOnTwoRecordsOnce() throws {
        let (counter, tallies) = try count([
            line("AAAC", "U1", record: "KK339487.1", pos: 1001), line("AAAC", "U1", record: "KK339488.1", pos: 50, nm: 4),
            line("AAAC", "U2", record: "KK339488.1", pos: 70, nm: 4),
        ], extras: [Self.mtb])
        XCTAssertEqual(counter.recordNames, ["KK339487.1", "KK339488.1"])
        XCTAssertEqual(tallies["AAAC"]?.records, [counts(0, 1, 0, 1), counts(2, 0, 0, 0)])
        // U1 is default over the genome since its alignment on KK339488.1 lies outside the mask, and near since one is.
        XCTAssertEqual(tallies["AAAC"]?.genome, [counts(2, 0, 1, 0)])
    }

    func testAHeaderThatLacksARecordOrHoldsItAtAnotherLengthIsRefusedInWords() throws {
        let records = [SingleCellNotHostRecord(name: "NC_045512.2", length: 29903)]
        XCTAssertNoThrow(try SingleCellNotHostCounter.checkHeader("@HD\tVN:1.4\n@SQ\tSN:NC_045512.2\tLN:29903\n", bam: "a.bam", records: records))
        XCTAssertThrowsError(try SingleCellNotHostCounter.checkHeader("@SQ\tSN:chr1\tLN:5\n", bam: "a.bam", records: records)) { error in
            XCTAssertEqual(error as? SingleCellNotHostError, .recordMissing(bam: "a.bam", record: "NC_045512.2"))
            XCTAssertTrue((error.localizedDescription).contains("a.bam holds no record NC_045512.2"), error.localizedDescription)
        }
        XCTAssertThrowsError(try SingleCellNotHostCounter.checkHeader("@SQ\tSN:NC_045512.2\tLN:29870\n", bam: "a.bam", records: records)) { error in
            XCTAssertEqual(error as? SingleCellNotHostError, .recordLength(bam: "a.bam", record: "NC_045512.2", bamLength: 29870, setLength: 29903))
        }
    }
}

// MARK: - The ambient pool, the four cases of GN with their own sizes

extension SingleCellNotHostTests {
    /// A 16-base barcode whose byte order is the order of `value`.
    static func barcode(_ value: Int) -> String {
        String((0..<16).reversed().map { Array("ACGT")[(value >> (2 * $0)) & 3] })
    }

    /// A raw matrix of `values.count` barcodes, the barcode of `values[i]` at index i, with the totals given.
    func raw(_ values: [Int], totals: [UInt64]) -> SingleCellRawMatrix {
        let text = values.map(Self.barcode).joined(separator: "\n") + "\n"
        return SingleCellRawMatrix(barcodes: SingleCellBarcodeTable(data: Data(text.utf8)), totals: totals)
    }

    func testAPoolWithNoNotHostUMIGetsTheRateOfOneOverItsUMIs() throws {
        // GSM8976786: 122,373 barcodes with a UMI and 0 not-host UMIs in its pool of 45,001.
        let withUMI = 122_373
        let totals = (0..<130_000).map { UInt64($0 < 44_999 ? 10 : $0 < 90_000 ? 2 : $0 < withUMI ? 1 : 0) }
        let raw = raw(Array(0..<130_000), totals: totals)
        let pool = SingleCellAmbientPool(raw)
        XCTAssertEqual(pool.barcodesWithUMI, withUMI)
        XCTAssertEqual(pool.members.count, 45_001)
        XCTAssertEqual(pool.firstRank, 45_000)
        XCTAssertEqual(pool.lastRank, 90_000)
        XCTAssertEqual(pool.umiRange, 2...2)
        XCTAssertEqual(pool.umis, 90_002)
        XCTAssertNil(pool.words)

        var counter = SingleCellNotHostCounter(extras: [Self.virus])
        try counter.add(samText: [line(Self.barcode(0), "U1"), line(Self.barcode(0), "U2"), line(Self.barcode(0), "U3"),
                                  line(Self.barcode(1), "U1"), line(Self.barcode(129_999), "U1")].joined(separator: "\n"))
        let sample = SingleCellNotHostPass.sample(
            "GSM8976786", cells: [Self.barcode(0), Self.barcode(1)], raw: raw, pool: pool, tallies: counter.tallies(), extras: [Self.virus])
        XCTAssertEqual(sample.poolGenome, [counts(0)])
        let rate = try XCTUnwrap(sample.rates[0])
        XCTAssertEqual(rate, 1.0 / 90_002, accuracy: 1e-18)
        // P(X >= 3) at 10 UMIs times the rate, by the series, since 1 - P(X < 3) cancels at this size.
        let mean = 10 * rate
        var term = exp(-mean)
        var tail = 0.0
        for j in 1...40 { term *= mean / Double(j); if j >= 3 { tail += term } }
        XCTAssertEqual(sample.calls.map(\.column), [0, 1])
        XCTAssertEqual(try XCTUnwrap(sample.calls[0].p) / tail, 1, accuracy: 1e-9)
        XCTAssertEqual(sample.calls[0].flag, "viral RNA above ambient")
        // One UMI never flags, whatever its q.
        XCTAssertEqual(sample.calls[1].flag, "")
        // The barcode outside the cells with a not-host UMI keeps its row, with 0 raw UMIs.
        let rows = Dictionary(uniqueKeysWithValues: sample.barcodes.map { ($0.barcode, $0) })
        XCTAssertEqual(rows[Self.barcode(129_999)]?.rawUMIs, 0)
        XCTAssertNil(rows[Self.barcode(129_999)]?.column)
        XCTAssertEqual(rows[Self.barcode(1)]?.column, 1)
    }

    func testAWindowWithFewerThan90000BarcodesRunsToTheLast() {
        // GSM8976784: 85,171 barcodes with a UMI, so the pool is ranks 45000-85171, 40,172 barcodes, all at 1 UMI.
        let totals = (0..<90_000).map { UInt64($0 < 44_999 ? 4 : $0 < 85_171 ? 1 : 0) }
        let pool = SingleCellAmbientPool(raw(Array(0..<90_000), totals: totals))
        XCTAssertEqual(pool.barcodesWithUMI, 85_171)
        XCTAssertEqual(pool.members.count, 40_172)
        XCTAssertEqual(pool.lastRank, 85_171)
        XCTAssertEqual(pool.umiRange, 1...1)
        XCTAssertEqual(pool.umis, 40_172)
    }

    func testFewerThan45000BarcodesMakeNoPoolAndTheCountsStillShow() throws {
        // GSM8976782: 33,206 barcodes with a UMI.
        let totals = (0..<40_000).map { UInt64($0 < 33_206 ? 3 : 0) }
        let raw = raw(Array(0..<40_000), totals: totals)
        let pool = SingleCellAmbientPool(raw)
        XCTAssertNil(pool.firstRank)
        XCTAssertTrue(pool.members.isEmpty)
        XCTAssertEqual(pool.words, "not computed: 33206 barcodes, too few for an ambient pool")
        var counter = SingleCellNotHostCounter(extras: [Self.virus])
        try counter.add(samText: [line(Self.barcode(5), "U1"), line(Self.barcode(5), "U2")].joined(separator: "\n"))
        let sample = SingleCellNotHostPass.sample(
            "GSM8976782", cells: [Self.barcode(5)], raw: raw, pool: pool, tallies: counter.tallies(), extras: [Self.virus])
        XCTAssertEqual(sample.calls.map(\.flag), ["not computed: 33206 barcodes, too few for an ambient pool"])
        XCTAssertNil(sample.calls[0].q)
        XCTAssertEqual(sample.rates, [nil])
        XCTAssertEqual(sample.barcodes.first { $0.barcode == Self.barcode(5) }?.genome, [counts(2)])
    }

    func testAPoolWhollyInOneTieTakesTheBarcodesInByteOrder() {
        // GSM5560907: 152,402 barcodes with a UMI and a pool of 45,001 all at 1 UMI. The raw list runs in reverse byte
        // order here, so a pool taken by file order would hold other barcodes.
        let count = 152_402
        let values = (0..<count).map { count - 1 - $0 }
        let pool = SingleCellAmbientPool(raw(values, totals: values.map { UInt64($0 < 44_999 ? 3 : 1) }))
        XCTAssertEqual(pool.members.count, 45_001)
        XCTAssertEqual(pool.umiRange, 1...1)
        XCTAssertEqual(Set(pool.members.map { values[$0] }), Set(44_999...89_999))
    }

    func testTheTailAndBenjaminiHochbergMatchScipyAndTheScripts() {
        // scipy.stats.poisson.sf(1, 0.5) and poisson.sf(4, 2.0).
        XCTAssertEqual(SingleCellNotHostFlag.upperTail(2, mean: 0.5), 0.09020401043104986, accuracy: 1e-15)
        XCTAssertEqual(SingleCellNotHostFlag.upperTail(5, mean: 2.0), 0.052653017343711125, accuracy: 1e-15)
        XCTAssertEqual(SingleCellNotHostFlag.upperTail(0, mean: 2.0), 1)
        let q = SingleCellNotHostFlag.benjaminiHochberg([0.01, 0.04, 0.03, 0.2])
        for (found, expected) in zip(q, [0.04, 0.04 * 4 / 3, 0.04 * 4 / 3, 0.2]) { XCTAssertEqual(found, expected, accuracy: 1e-15) }
        XCTAssertEqual(SingleCellNotHostFlag.rate(notHostUMIs: 18, poolUMIs: 114_964), 19.0 / 114_964)
    }

    func testEachKindGetsItsWordsAndASpikeInGetsCountsAndNoFlag() throws {
        let unmasked = SingleCellNotHostExtra(name: "mtb-erdman", kind: .bacterium, records: ["KK339487.1"], mask: nil)
        let spike = SingleCellNotHostExtra(name: "ercc", kind: .spikeIn, records: ["ERCC-00002"], mask: nil)
        let extras = [Self.virus, unmasked, spike]
        let totals = (0..<100_000).map { UInt64($0 < 44_999 ? 50 : 1) }
        let raw = raw(Array(0..<100_000), totals: totals)
        var counter = SingleCellNotHostCounter(extras: extras)
        try counter.add(samText: (1...6).flatMap { umi in
            ["NC_045512.2", "KK339487.1", "ERCC-00002"].map { line(Self.barcode(0), "U\(umi)", record: $0) }
        }.joined(separator: "\n"))
        let sample = SingleCellNotHostPass.sample(
            "S1", cells: [Self.barcode(0)], raw: raw, pool: SingleCellAmbientPool(raw), tallies: counter.tallies(), extras: extras)
        XCTAssertEqual(sample.calls.map(\.extra), [0, 1])
        XCTAssertEqual(sample.calls[0].flag, "viral RNA above ambient")
        // A bacterium counted without its rRNA mask is never flagged (BIO-NOTHOST-BARCODE item 6).
        XCTAssertEqual(sample.calls[1].flag, "not computed: no rRNA mask for mtb-erdman")
        XCTAssertNil(sample.calls[1].q)
        XCTAssertEqual(sample.barcodes[0].genome, [counts(6), counts(6), counts(6)])
        XCTAssertEqual(SingleCellNotHostFlag.words(for: .bacterium), "bacterial RNA above ambient")
        XCTAssertNil(SingleCellNotHostFlag.words(for: .spikeIn))
        XCTAssertEqual(Self.mask.maskedWords, "on Mtb Erdman rRNA genes, source not resolved")
        XCTAssertEqual(unmasked.maskWords, "rRNA not masked: no annotation given for mtb-erdman")
        XCTAssertFalse((sample.calls.map(\.flag) + [unmasked.maskWords]).joined().lowercased().contains("infected"))
    }

    func testRawBarcodesAreHeldByIndexInOneBuffer() {
        let table = SingleCellBarcodeTable(data: Data("TTTA\r\nAAAC\nGGGT\n".utf8))
        XCTAssertEqual(table.count, 3)
        XCTAssertFalse(table.isSorted)
        XCTAssertEqual((0..<3).map(table.barcode(at:)), ["TTTA", "AAAC", "GGGT"])
        XCTAssertEqual(table.index(of: "GGGT"), 2)
        XCTAssertEqual(table.index(of: "AAAC"), 1)
        XCTAssertNil(table.index(of: "CCCC"))
        XCTAssertTrue(SingleCellBarcodeTable(data: Data("AAAC\nAAAG\n".utf8)).isSorted)
    }

    func testAStarsoloFolderWithNoSummaryImports() throws {
        // The GSE296788 stage imports a copy of topcells/ with no Summary.csv (BIO-NOTHOST-BARCODE item 16).
        let root = try TestTempDirectory.make(prefix: "single-cell-no-summary")
        defer { TestTempDirectory.cleanup(root) }
        let run = root.appendingPathComponent("GSM1", isDirectory: true)
        let filtered = run.appendingPathComponent("Solo.out/Gene/filtered", isDirectory: true)
        try FileManager.default.createDirectory(at: filtered, withIntermediateDirectories: true)
        try Data("%%MatrixMarket matrix coordinate integer general\n%\n2 2 2\n1 1 3\n2 2 1\n".utf8)
            .write(to: filtered.appendingPathComponent("matrix.mtx"))
        try Data("G1\tg1\tGene Expression\nG2\tg2\tGene Expression\n".utf8).write(to: filtered.appendingPathComponent("features.tsv"))
        try Data("AAAC\nCCCG\n".utf8).write(to: filtered.appendingPathComponent("barcodes.tsv"))
        let folder = try SingleCellFolderReader.read(folder: run)
        XCTAssertEqual(folder.tool, .starsolo)
        XCTAssertEqual(folder.keptFiles, ["Solo.out/Gene/filtered/barcodes.tsv", "Solo.out/Gene/filtered/features.tsv", "Solo.out/Gene/filtered/matrix.mtx"])
        XCTAssertTrue(folder.qualityColumns.isEmpty)
        XCTAssertNil(try SingleCellFolderReader.request([folder], name: "n", samples: [.init(id: "GSM1")], genomes: []).quality)
    }
}

// MARK: - cells.sqlite schema 2

extension SingleCellNotHostTests {
    func testASchema1CellsFileStillOpens() throws {
        let root = try TestTempDirectory.make(prefix: "cells-schema-1")
        defer { TestTempDirectory.cleanup(root) }
        let url = root.appendingPathComponent("cells.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for sql in [
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)", "INSERT INTO meta VALUES ('schema_version', '1')",
            "CREATE TABLE cells (cell INTEGER PRIMARY KEY, sample INTEGER NOT NULL, \"column\" INTEGER NOT NULL, barcode TEXT NOT NULL, umis INTEGER NOT NULL, genes INTEGER NOT NULL)",
            "INSERT INTO cells VALUES (1, 1, 1, 'AAAC', 5, 2)",
        ] { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        sqlite3_close(db)
        let cells = try RNASeqCellsDatabase(url: url)
        XCTAssertEqual(cells.schemaVersion, 1)
        XCTAssertEqual(try cells.cellCount(), 1)
        XCTAssertEqual(try cells.notHostExtras(), [])
        XCTAssertEqual(try cells.ambientPools(), [])
        XCTAssertEqual(try cells.notHostCalls(), [])
    }

    func testTheWriterKeepsTheNotHostTablesAndAMovedResultOpensThemWithoutTheBAMOrRawMatrix() throws {
        let root = try TestTempDirectory.make(prefix: "cells-schema-2")
        defer { TestTempDirectory.cleanup(root) }
        let folder = try SingleCellFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true))
        let cells = try MatrixMarketReader.textLines(of: folder.url.appendingPathComponent(folder.barcodes))
        // The raw list is the cells and 50,000 more barcodes at 1 UMI, which puts the cells first and a pool behind.
        let extraBarcodes = (0..<50_000).map { Self.barcode($0) }
        let text = (cells + extraBarcodes).joined(separator: "\n") + "\n"
        let raw = SingleCellRawMatrix(
            barcodes: SingleCellBarcodeTable(data: Data(text.utf8)), totals: cells.map { _ in 900 } + extraBarcodes.map { _ in 1 })
        var counter = SingleCellNotHostCounter(extras: [Self.virus])
        try counter.add(samText: (1...4).map { line(cells[0], "U\($0)") }.joined(separator: "\n") + "\n" + line(Self.barcode(7), "U1"))
        let sample = SingleCellNotHostPass.sample(
            folder.sample, cells: cells, raw: raw, pool: SingleCellAmbientPool(raw), tallies: counter.tallies(), extras: [Self.virus])
        var request = try SingleCellFolderReader.request([folder], name: "pbmc", samples: [.init(id: folder.sample)], genomes: [])
        request.notHostCells = SingleCellNotHostResult(
            extras: [Self.virus], records: [.init(name: "NC_045512.2", length: 29903)], samples: [sample])
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let result = try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(
            request, to: analyses.appendingPathComponent("pbmc.lungfishrnaseq"),
            envelope: ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test"))
        let moved = root.appendingPathComponent("elsewhere.lungfishrnaseq")
        try FileManager.default.moveItem(at: result, to: moved)

        let database = try RNASeqCellsDatabase(url: moved.appendingPathComponent(RNASeqCellsDatabase.filename))
        XCTAssertEqual(database.schemaVersion, 2)
        XCTAssertEqual(try database.notHostExtras().map(\.name), ["sars-cov-2"])
        XCTAssertEqual(try database.notHostRecords().map(\.length), [29903])
        let pool = try XCTUnwrap(try database.ambientPools().first)
        // Fewer than 90,000 barcodes hold a UMI, so the window runs to the last.
        let withUMI = cells.count + 50_000
        XCTAssertEqual([pool.barcodesWithUMI, pool.poolBarcodes, pool.firstRank, pool.lastRank], [withUMI, withUMI - 44_999, 45_000, withUMI])
        let calls = try database.notHostCalls()
        XCTAssertEqual(calls.count, cells.count)
        XCTAssertEqual(calls.first { $0.cell == 1 }?.flag, "viral RNA above ambient")
        let counted = try database.notHostCounts()
        XCTAssertEqual(counted.filter { $0.barcode == cells[0] }.map { [$0.record, $0.umis, $0.umisNM01] }, [[0, 4, 4], [1, 4, 4]])
        XCTAssertEqual(try database.notHostBarcodes().first { $0.barcode == Self.barcode(7) }?.cell, nil)
        XCTAssertEqual(try database.notHostBarcodes().first { $0.barcode == cells[0] }?.cell, 1)
    }
}
