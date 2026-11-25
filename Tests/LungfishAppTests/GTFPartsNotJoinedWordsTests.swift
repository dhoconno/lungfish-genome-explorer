// GTFPartsNotJoinedWordsTests.swift - The words for a GTF transcript or CDS that an older version stored in parts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// AFFECTED-ANNOT-2 (AFFECTED-WORDS-17 item 3). A bundle built before the GTF-SPLICE fix keeps blockless GTF rows: a
// `transcript` row has one interval and each GTF `CDS` line is its own row. Asking for exons joined then keeps the
// introns, and a translation holds one exon's piece. These tests hold the pure function that decides when the words
// show, the one query that counts the sibling rows, the track databases it reads, the report, and that the three
// routes call it.

import AppKit
import XCTest
import SQLite3
@testable import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class GTFPartsNotJoinedWordsTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        // A route that shows its words with no recorder bound would run an alert no test answers, so a test stops at
        // its first failed assertion.
        continueAfterFailure = false
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

    // MARK: - The routes, driven for real (review of AFFECTED-ANNOT: B1, SF-1, SF-2, SF-3, AA-3)

    /// Records the words a route shows, so no alert opens and the test reads them.
    @MainActor
    private final class WordsRecorder: ViewerRefusalPresenting {
        private(set) var reports: [FailureReport] = []

        func present(_ report: FailureReport, in window: NSWindow?) {
            reports.append(report)
        }
    }

    private let chromosome = "chr1"
    /// 3,006 bases of in-frame codons, so a one-part CDS translates and no stop codon cuts it short.
    private let bases = String(repeating: "ATGGCTAAA", count: 334)
    private var retainedController: ViewerViewController?
    private var operationDialogs = 0

    /// The ruling's sentences for each route, written out in full so a change to one word fails here. The CDS forms are
    /// in the review of AFFECTED-ANNOT, SF-2. The transcript form for a copy puts "copy it" where the ruling says "extract it".
    private let cdsTranslationWords = "This CDS is one of several parts in a GTF track that an older version stored separately, so this protein is only part of it. Attach the GTF file again to join the parts, then copy the translation again."
    private let cdsCopyWords = "This CDS is one of several parts in a GTF track that an older version stored separately, so this sequence is only part of it. Attach the GTF file again to join the parts, then copy it again."
    private let cdsExtractionWords = "This CDS is one of several parts in a GTF track that an older version stored separately, so this sequence is only part of it. Attach the GTF file again to join the parts, then extract it again."
    private let transcriptCopyWords = "This transcript came from a GTF track that an older version stored as one part, so this sequence includes its introns. Attach the GTF file again to join its exons, then copy it again."

    /// A viewer on a reference bundle with a sequence and one GTF track, `genes`, as an older version stored it: a
    /// `transcript` row of one part and each `CDS` line its own row, all with their `transcript_id`. T1 has two exons and
    /// two CDS lines. T2 has one exon, with the transcript's own span.
    private func makeViewerOnGTFBundle() throws -> SequenceViewerView {
        let bundleURL = scratch.appendingPathComponent("gtf.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations", isDirectory: true), withIntermediateDirectories: true
        )
        let header = ">\(chromosome)\n"
        try "\(header)\(bases)\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        try "\(chromosome)\t\(bases.count)\t\(header.utf8.count)\t\(bases.count)\t\(bases.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        _ = try writeDatabase("gtf.lungfishref/annotations/genes.db", rows: [
            ("transcript", chromosome, 100, 900, "gene_id=G;transcript_id=T1"),
            ("exon", chromosome, 100, 200, "gene_id=G;transcript_id=T1"),
            ("exon", chromosome, 700, 900, "gene_id=G;transcript_id=T1"),
            ("CDS", chromosome, 150, 201, "gene_id=G;transcript_id=T1"),
            ("CDS", chromosome, 700, 850, "gene_id=G;transcript_id=T1"),
            ("transcript", chromosome, 2000, 2500, "gene_id=G;transcript_id=T2"),
            ("exon", chromosome, 2000, 2500, "gene_id=G;transcript_id=T2"),
        ])
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "GTF words",
            identifier: "org.lungfish.tests.gtf-words",
            source: SourceInfo(organism: "Test organism", assembly: "gtf-words"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(bases.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosome, length: Int64(bases.count), offset: Int64(header.utf8.count),
                        lineBases: bases.count, lineWidth: bases.count + 1
                    )
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes", name: "genes", path: "annotations/genes.bb",
                    databasePath: "annotations/genes.db", featureCount: 7
                )
            ]
        )
        try manifest.save(to: bundleURL)
        let controller = ViewerViewController()
        controller.loadView()
        retainedController = controller
        // The FASTQ/FASTA operation dialog is counted and not shown.
        controller.fastaOperationDialogPresenterForTesting = { [weak self] _, _, _, _ in self?.operationDialogs += 1 }
        let viewer = try XCTUnwrap(controller.viewerView)
        viewer.viewController = controller
        viewer.setReferenceBundle(ReferenceBundle(url: bundleURL, manifest: manifest))
        return viewer
    }

    /// A row of the track as the viewer builds it from the database, with no track id.
    private func annotation(_ type: String, _ start: Int, _ end: Int, id: String) -> SequenceAnnotation {
        AnnotationDatabaseRecord(
            name: "\(id) \(type)", type: type, chromosome: chromosome, start: start, end: end, strand: "+",
            attributes: "gene_id=G;transcript_id=\(id)"
        ).toAnnotation()
    }

    /// The reports a route presents, with a recording presenter bound and the clipboard put back as it was.
    private func reportsShown(by viewer: SequenceViewerView, _ route: (SequenceViewerView) -> Void) -> [FailureReport] {
        let recorder = WordsRecorder()
        let board = NSPasteboard.general
        let before = board.string(forType: .string)
        defer {
            board.clearContents()
            if let before { board.setString(before, forType: .string) }
        }
        ViewerRefusalSeam.$presenter.withValue(recorder) { route(viewer) }
        return recorder.reports
    }

    private func sentences(_ reports: [FailureReport]) -> [String] {
        reports.map { $0.whatHappened + " " + $0.nextStep }
    }

    /// B1 and SF-3: a real annotation row from the track database, taken through the real Copy as FASTA route and its
    /// own request, so a call that moves ahead of the clipboard write, into a dead branch or after a refusal shows here.
    /// The dialog sends no tick for a one-part row, so the transcript words must show with none.
    func testAOnePartGTFTranscriptAndCDSGetTheirWordsFromTheRealRequestAndAnOneExonTranscriptGetsNone() throws {
        let viewer = try makeViewerOnGTFBundle()

        let transcript = sentences(reportsShown(by: viewer) {
            $0.copyAnnotationAsFASTAImpl(annotation("transcript", 100, 900, id: "T1"))
        })
        XCTAssertEqual(transcript, [transcriptCopyWords], "a one-part transcript of an old GTF track copied with its introns and no words")

        let cds = sentences(reportsShown(by: viewer) {
            $0.copyAnnotationAsFASTAImpl(annotation("CDS", 150, 201, id: "T1"))
        })
        XCTAssertEqual(cds, [cdsCopyWords], "one CDS line of an old GTF track copied as the whole CDS and no words")

        let oneExon = sentences(reportsShown(by: viewer) {
            $0.copyAnnotationAsFASTAImpl(annotation("transcript", 2000, 2500, id: "T2"))
        })
        XCTAssertEqual(oneExon, [], "a true one-exon transcript is one part and gets no words")
    }

    /// SF-1: the sheet's title is true after a copy that worked. It says what could not be joined, for a transcript, an
    /// mRNA and a CDS, and never "Could not copy".
    func testTheSheetTitleNamesTheJoinThatDidNotHappenForEachType() throws {
        let viewer = try makeViewerOnGTFBundle()

        for type in ["transcript", "mRNA"] {
            let reports = reportsShown(by: viewer) { $0.copyAnnotationAsFASTAImpl(annotation(type, 100, 900, id: "T1")) }
            XCTAssertEqual(reports.map(\.title), ["Could not join the exons of this transcript"], type)
        }
        let copy = reportsShown(by: viewer) { $0.copyAnnotationAsFASTAImpl(annotation("CDS", 150, 201, id: "T1")) }
        XCTAssertEqual(copy.map(\.title), ["Could not join the parts of this CDS"])
        let translation = reportsShown(by: viewer) {
            $0.copyAnnotationTranslationAsFASTAImpl(annotation("CDS", 150, 201, id: "T1"))
        }
        XCTAssertEqual(translation.map(\.title), ["Could not join the parts of this CDS"])
    }

    /// SF-2: each route says what it did. Copy translation says protein and "copy the translation again". A copy of the
    /// nucleotides says sequence and "copy it again". An extraction says sequence and "extract it again".
    func testEachRoutesWordsAreTheRulingsFormForThatRoute() throws {
        let viewer = try makeViewerOnGTFBundle()
        let transcript = annotation("transcript", 100, 900, id: "T1")
        let cds = annotation("CDS", 150, 201, id: "T1")

        XCTAssertEqual(sentences(reportsShown(by: viewer) { $0.copyAnnotationAsFASTAImpl(transcript) }), [transcriptCopyWords])
        XCTAssertEqual(sentences(reportsShown(by: viewer) { $0.copyAnnotationAsFASTAImpl(cds) }), [cdsCopyWords])
        XCTAssertEqual(
            sentences(reportsShown(by: viewer) { $0.copyAnnotationTranslationAsFASTAImpl(cds) }), [cdsTranslationWords]
        )
        XCTAssertEqual(
            sentences(reportsShown(by: viewer) { $0.runAnnotationFASTAOperationImpl(transcript) }), [transcriptWords]
        )
        XCTAssertEqual(
            sentences(reportsShown(by: viewer) { $0.runAnnotationFASTAOperationImpl(cds) }), [cdsExtractionWords]
        )
    }

    /// AA-3, Extract to a FASTA file: the same one-part rows get the words, in the extraction form. A selection of a
    /// transcript, two CDS lines and a one-exon transcript gets one sheet for each sentence it earns, in selection order.
    func testExtractToAFASTAFileSaysSoForOnePartGTFRows() throws {
        let viewer = try makeViewerOnGTFBundle()

        XCTAssertEqual(
            sentences(reportsShown(by: viewer) { $0.presentAnnotationSequenceExtractionDialog([annotation("CDS", 150, 201, id: "T1")]) }),
            [cdsExtractionWords], "one CDS line of an old GTF track extracted to a file with no words"
        )
        XCTAssertEqual(
            sentences(reportsShown(by: viewer) {
                $0.presentAnnotationSequenceExtractionDialog([annotation("transcript", 2000, 2500, id: "T2")])
            }),
            [], "a one-exon transcript gets no words"
        )
        let selection = [
            annotation("transcript", 2000, 2500, id: "T2"), annotation("transcript", 100, 900, id: "T1"),
            annotation("CDS", 150, 201, id: "T1"), annotation("CDS", 700, 850, id: "T1"),
        ]
        XCTAssertEqual(
            sentences(reportsShown(by: viewer) { $0.presentAnnotationSequenceExtractionDialog(selection) }),
            [transcriptWords, cdsExtractionWords]
        )
    }

    /// AA-3, the FASTQ/FASTA operation: the dialog opens, and the words follow it in the extraction form. A one-exon
    /// transcript opens the dialog and gets none.
    func testTheFASTQFASTAOperationSaysSoForOnePartGTFRows() throws {
        let viewer = try makeViewerOnGTFBundle()

        let quiet = reportsShown(by: viewer) { $0.runAnnotationFASTAOperationImpl(annotation("transcript", 2000, 2500, id: "T2")) }
        XCTAssertEqual(operationDialogs, 1, "the operation dialog opens for a one-exon transcript")
        XCTAssertEqual(sentences(quiet), [])

        let words = reportsShown(by: viewer) { $0.runAnnotationFASTAOperationImpl(annotation("CDS", 150, 201, id: "T1")) }
        XCTAssertEqual(operationDialogs, 2, "the operation dialog opens for the CDS line")
        XCTAssertEqual(sentences(words), [cdsExtractionWords])
    }
}
