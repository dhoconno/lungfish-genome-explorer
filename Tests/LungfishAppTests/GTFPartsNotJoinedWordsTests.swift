// GTFPartsNotJoinedWordsTests.swift - The words for a GTF transcript or CDS that an older version stored in parts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// AFFECTED-ANNOT-2 (AFFECTED-WORDS-17 item 3). A bundle built before the GTF-SPLICE fix keeps blockless GTF rows: a
// `transcript` row has one interval and each GTF `CDS` line is its own row. Asking for exons joined then keeps the
// introns, and a translation holds one exon's piece. These tests hold the pure function that decides when the words
// show, the one query that counts the sibling rows, the track databases it reads, the report, and that the three
// routes call it.

import XCTest
import SQLite3
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class GTFPartsNotJoinedWordsTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "gtf-parts-not-joined")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    /// The two sentences of `SCR/rulings/AFFECTED-WORDS-17.md`, item 3, as the ruling gives them.
    private let transcriptWords = "This transcript came from a GTF track that an older version stored as one part, so this sequence includes its introns. Attach the GTF file again to join its exons, then extract it again."
    private let cdsWords = "This CDS is one of several parts in a GTF track that an older version stored separately, so this protein is only part of it. Attach the GTF file again to join the parts, then copy the translation again."

    private let gtfAttributes = ["transcript_id": "T1", "gene_id": "G1"]

    // MARK: - The pure function

    func testTheWordsAreTheRulingsExactSentences() {
        XCTAssertEqual(GTFPartsNotJoined.transcriptWords, transcriptWords)
        XCTAssertEqual(GTFPartsNotJoined.cdsWords, cdsWords)
    }

    /// A one-part transcript or mRNA row with a `transcript_id`, in a track that holds a sibling exon row, gets the
    /// transcript words once exons are to be joined.
    func testAOnePartTranscriptWithSiblingExonsGetsTheTranscriptWordsWhenExonsAreJoined() {
        for type in [AnnotationType.transcript, .mRNA] {
            XCTAssertEqual(
                GTFPartsNotJoined.words(
                    type: type, partCount: 1, attributes: gtfAttributes, concatenateExons: true, siblingCount: 3
                ),
                transcriptWords, "\(type)"
            )
        }
    }

    /// Without the tick for joined exons the transcript sequence is the span the person asked for, so the words stay
    /// away, and the query for the sibling rows is never run.
    func testATranscriptWithoutJoinedExonsGetsNoWordsAndRunsNoQuery() {
        var queries = 0
        for type in [AnnotationType.transcript, .mRNA] {
            let words = GTFPartsNotJoined.words(
                type: type, partCount: 1, attributes: gtfAttributes, concatenateExons: false,
                siblingCount: { queries += 1; return 3 }()
            )
            XCTAssertNil(words, "\(type)")
        }
        XCTAssertEqual(queries, 0, "the query ran for a feature that cannot get the words")
    }

    /// A one-part CDS row with a sibling CDS row gets the CDS words, ticked or not, since each CDS line is a piece.
    func testAOnePartCDSWithASiblingCDSGetsTheCDSWords() {
        for concatenate in [true, false] {
            XCTAssertEqual(
                GTFPartsNotJoined.words(
                    type: .cds, partCount: 1, attributes: gtfAttributes, concatenateExons: concatenate, siblingCount: 1
                ),
                cdsWords, "concatenate \(concatenate)"
            )
        }
    }

    /// A true one-exon transcript has no other exon row, and a CDS of one line has no other CDS row.
    func testATrueOneExonTranscriptAndALoneCDSGetNoWords() {
        for type in [AnnotationType.transcript, .mRNA, .cds] {
            XCTAssertNil(
                GTFPartsNotJoined.words(
                    type: type, partCount: 1, attributes: gtfAttributes, concatenateExons: true, siblingCount: 0
                ),
                "\(type)"
            )
        }
    }

    /// A GFF3 row never gets the words. Its mRNA holds blocks and its CDS is merged by `ID`, so a row of several parts
    /// is left alone before any query runs, and a GFF3 row with no `transcript_id` has nothing to look up.
    func testAGFF3RowNeverGetsTheWords() {
        var queries = 0
        let ncbi = ["ID": "rna-NM_1", "Parent": "gene-A", "transcript_id": "NM_1"]
        XCTAssertNil(GTFPartsNotJoined.words(
            type: .mRNA, partCount: 3, attributes: ncbi, concatenateExons: true,
            siblingCount: { queries += 1; return 3 }()
        ))
        XCTAssertNil(GTFPartsNotJoined.words(
            type: .cds, partCount: 2, attributes: ncbi, concatenateExons: true,
            siblingCount: { queries += 1; return 3 }()
        ))
        let ensembl = ["ID": "transcript:ENST1", "Parent": "gene:ENSG1"]
        XCTAssertNil(GTFPartsNotJoined.words(
            type: .mRNA, partCount: 1, attributes: ensembl, concatenateExons: true,
            siblingCount: { queries += 1; return 3 }()
        ))
        XCTAssertEqual(queries, 0, "a GFF3 row ran the query")
    }

    /// Only a transcript, mRNA or CDS row can get the words.
    func testOtherTypesGetNoWords() {
        for type in [AnnotationType.gene, .exon, .region] {
            XCTAssertNil(
                GTFPartsNotJoined.words(
                    type: type, partCount: 1, attributes: gtfAttributes, concatenateExons: true, siblingCount: 3
                ),
                "\(type)"
            )
        }
    }

    // MARK: - The one query

    private typealias Row = (type: String, chromosome: String, start: Int, end: Int, attributes: String?)

    /// A database with the `annotations` table of the bundle's annotation databases and the rows it is given.
    private func writeDatabase(_ name: String, rows: [Row]) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var statements = [
            "CREATE TABLE annotations (name TEXT, type TEXT, chromosome TEXT, start INTEGER, \"end\" INTEGER, strand TEXT, attributes TEXT, block_count INTEGER, block_sizes TEXT, block_starts TEXT, gene_name TEXT)"
        ]
        for row in rows {
            let attributes = row.attributes.map { "'\($0)'" } ?? "NULL"
            statements.append(
                "INSERT INTO annotations (name, type, chromosome, start, \"end\", strand, attributes) VALUES ('n', '\(row.type)', '\(row.chromosome)', \(row.start), \(row.end), '+', \(attributes))"
            )
        }
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        return url
    }

    private func count(
        _ database: URL, _ partType: String, id: String, chromosome: String = "chr1", span: (start: Int, end: Int) = (100, 900)
    ) -> Int {
        GTFPartsNotJoined.siblingRowCount(
            in: database, partType: partType, chromosome: chromosome, transcriptID: id,
            excludingStart: span.start, excludingEnd: span.end
        )
    }

    /// The exon rows of one transcript are counted wherever `transcript_id` sits in the attribute text, and the rows of
    /// another transcript, of another case, of a key that only ends in `transcript_id`, of another chromosome and with
    /// no attributes are not.
    func testTheQueryCountsTheExonRowsOfOneTranscriptOnly() throws {
        let database = try writeDatabase("exons.db", rows: [
            ("transcript", "chr1", 100, 900, "gene_id=G1;transcript_id=T1"),
            ("exon", "chr1", 100, 200, "gene_id=G1;transcript_id=T1"),
            ("exon", "chr1", 300, 400, "transcript_id=T1;gene_id=G1"),
            ("exon", "chr1", 500, 600, "a=b;transcript_id=T1;gene_id=G1"),
            ("exon", "chr1", 800, 900, "transcript_id=T1"),
            ("exon", "chr1", 1000, 1100, "transcript_id=T10"),
            ("exon", "chr1", 1200, 1300, "transcript_id=t1"),
            ("exon", "chr1", 1400, 1500, "old_transcript_id=T1"),
            ("exon", "chr2", 100, 200, "transcript_id=T1"),
            ("exon", "chr1", 1600, 1700, nil),
        ])
        XCTAssertEqual(count(database, "exon", id: "T1"), 4)
        XCTAssertEqual(count(database, "exon", id: "T10"), 1)
        XCTAssertEqual(count(database, "exon", id: "T2"), 0)
    }

    /// A true one-exon transcript, whose one exon row has the transcript's own span, has no sibling.
    func testATrueOneExonTranscriptHasNoSiblingRow() throws {
        let database = try writeDatabase("one-exon.db", rows: [
            ("transcript", "chr1", 100, 900, "transcript_id=T2"),
            ("exon", "chr1", 100, 900, "transcript_id=T2"),
        ])
        XCTAssertEqual(count(database, "exon", id: "T2"), 0)
    }

    /// A CDS row counts the other CDS lines of its transcript and not itself.
    func testACDSRowCountsTheOtherCDSLinesOfItsTranscript() throws {
        let database = try writeDatabase("cds.db", rows: [
            ("CDS", "chr1", 100, 200, "gene_id=G3;transcript_id=T3"),
            ("CDS", "chr1", 300, 400, "gene_id=G3;transcript_id=T3"),
            ("CDS", "chr1", 500, 600, "gene_id=G4;transcript_id=T4"),
            ("exon", "chr1", 100, 200, "transcript_id=T3"),
        ])
        XCTAssertEqual(count(database, "CDS", id: "T3", span: (100, 200)), 1)
        XCTAssertEqual(count(database, "CDS", id: "T4", span: (500, 600)), 0)
    }

    /// A GFF3 track keeps its exons under `Parent`, so nothing in it matches.
    func testAGFF3TrackHasNoSiblingRow() throws {
        let database = try writeDatabase("gff3.db", rows: [
            ("mRNA", "chr1", 100, 900, "ID=transcript:T1;Parent=gene:G1"),
            ("exon", "chr1", 100, 200, "ID=exon1;Parent=transcript:T1"),
            ("exon", "chr1", 300, 400, "ID=exon2;Parent=transcript:T1"),
        ])
        XCTAssertEqual(count(database, "exon", id: "T1"), 0)
        XCTAssertEqual(count(database, "exon", id: "transcript:T1"), 0)
    }

    /// The stored text encodes `,` as `%2C`, so an id with a comma is looked up as stored.
    func testAnIDWithAnEncodedCharacterIsLookedUpAsStored() throws {
        let database = try writeDatabase("encoded.db", rows: [
            ("exon", "chr1", 100, 200, "transcript_id=T%2C1"),
            ("exon", "chr1", 300, 400, "transcript_id=T%2C1"),
        ])
        XCTAssertEqual(count(database, "exon", id: "T,1", span: (100, 900)), 2)
    }

    /// A database that cannot be opened counts as no sibling, so no words show and nothing fails.
    func testAMissingDatabaseCountsNothing() {
        XCTAssertEqual(count(scratch.appendingPathComponent("absent.db"), "exon", id: "T1"), 0)
    }

    // MARK: - The track databases

    func testTheTrackDatabasesAreThoseOfTheNamedTrackAndStayInsideTheBundle() throws {
        let bundle = scratch.appendingPathComponent("ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("annotations"), withIntermediateDirectories: true
        )
        for name in ["annotations/genes.db", "annotations/other.db"] {
            FileManager.default.createFile(atPath: bundle.appendingPathComponent(name).path, contents: Data())
        }
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("outside.db").path, contents: Data())
        let tracks: [(id: String, databasePath: String?)] = [
            ("genes", "annotations/genes.db"), ("other", "annotations/other.db"), ("escape", "../outside.db"),
            ("missing", "annotations/missing.db"), ("none", nil),
        ]

        let all = GTFPartsNotJoined.databaseURLs(inBundleAt: bundle, tracks: tracks, trackID: nil)
        XCTAssertEqual(all.map(\.lastPathComponent), ["genes.db", "other.db"])
        let named = GTFPartsNotJoined.databaseURLs(inBundleAt: bundle, tracks: tracks, trackID: "other")
        XCTAssertEqual(named.map(\.lastPathComponent), ["other.db"])
        XCTAssertEqual(GTFPartsNotJoined.databaseURLs(inBundleAt: bundle, tracks: tracks, trackID: "escape"), [])
    }

    // MARK: - The report

    /// The ruling's two sentences become what happened and the next step of the report, and put together read as given.
    func testTheReportSplitsTheTwoSentencesIntoWhatHappenedAndTheNextStep() {
        for words in [transcriptWords, cdsWords] {
            let report = GTFPartsNotJoined.report(words: words, step: "Copy the translation as FASTA")
            XCTAssertEqual(report.failedStep, "Copy the translation as FASTA")
            XCTAssertEqual(report.whatHappened + " " + report.nextStep, words)
            XCTAssertTrue(report.whatHappened.hasSuffix("."), report.whatHappened)
            XCTAssertTrue(report.nextStep.hasPrefix("Attach the GTF file again"), report.nextStep)
        }
    }

    // MARK: - The three routes

    /// The routes end in a window and a bundle that a test cannot build cheaply, since the viewer keeps its bundle
    /// private to its loader, so each route is held by what its body calls.
    private func body(from start: String, upTo end: String) throws -> Substring {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift"),
            encoding: .utf8
        )
        let from = try XCTUnwrap(source.range(of: start), "\(start) is not in the extraction file")
        let to = try XCTUnwrap(
            source.range(of: end, range: from.upperBound..<source.endIndex), "\(end) is not in the extraction file"
        )
        return source[from.upperBound..<to.lowerBound]
    }

    func testCopyAsFASTACallsTheWords() throws {
        let text = try body(from: "func copyAnnotationAsFASTAImpl(", upTo: "@objc func runAnnotationFASTAOperation(")
        XCTAssertTrue(text.contains("presentGTFPartsNotJoinedWords(for: request"), "Copy as FASTA does not call the words")
    }

    func testCopyTranslationCallsTheWords() throws {
        let text = try body(from: "func copyAnnotationTranslationAsFASTAImpl(", upTo: "// MARK: - Selection FASTA Action")
        XCTAssertTrue(text.contains("presentGTFPartsNotJoinedWords(for: request"), "Copy translation does not call the words")
    }

    func testAnExtractionCallsTheWords() throws {
        let text = try body(from: "private func performExtraction(", upTo: "func createExtractionBundle(")
        XCTAssertTrue(text.contains("presentGTFPartsNotJoinedWords(for: request"), "an extraction does not call the words")
    }
}
