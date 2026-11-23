import XCTest
@testable import LungfishKit
@testable import LungfishCore
@testable import LungfishWorkflow

/// The BLAST results tab's summary text. The tab's CSV and TSV export no longer writes a file of its own. It runs
/// `lungfish-cli blast export table` on the file the shown result was read from, which
/// BlastTableExportCLIGUIParityReplayTests covers.
@MainActor
final class BlastResultsDrawerTabExportTests: XCTestCase {
    private func makeResult() -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "Oxbow virus",
            taxId: 12345,
            readResults: [],
            submittedAt: Date(),
            completedAt: Date(),
            rid: "TEST-RID",
            blastProgram: "blastn",
            database: "nt"
        )
    }

    /// Capture on 9.70: an NVD contig's verification read "(1 reads)".
    func testVerificationSummaryCountsOneReadInTheSingular() {
        var result = makeResult()
        XCTAssertTrue(BlastResultsDrawerTab.verificationSummary(for: result).hasSuffix("(0 reads)"))
        result = BlastVerificationResult(
            taxonName: "SARS-CoV-2",
            taxId: 2697049,
            readResults: [BlastReadResult(id: "NODE_1", verdict: .verified)],
            submittedAt: Date(),
            completedAt: Date(),
            rid: "TEST-RID",
            blastProgram: "blastn",
            database: "core_nt"
        )
        XCTAssertTrue(BlastResultsDrawerTab.verificationSummary(for: result).hasSuffix("(1 read)"))
    }

    /// A pin for lane ROWPANE. With no sample named, the summary still opens with the taxon and its colon, so the
    /// words of a result that has no sample to name do not change.
    func testSummaryWithNoSubjectStartsWithTheTaxon() {
        XCTAssertTrue(
            BlastResultsDrawerTab.verificationSummary(for: makeResult()).hasPrefix("BLAST for Oxbow virus: "),
            BlastResultsDrawerTab.verificationSummary(for: makeResult())
        )
    }

    /// The sample goes right after the taxon, so the label's cut tail never takes the counts, and an empty name names
    /// nothing. These two read the new `subject` parameter, so they cannot compile at the base (lane ROWPANE).
    func testSummaryNamesTheSubjectRightAfterTheTaxon() {
        let result = makeResult()
        XCTAssertEqual(
            BlastResultsDrawerTab.verificationSummary(for: result, subject: "S2"),
            "BLAST for Oxbow virus (sample S2): 0 supporting, 0 contradicting (0 reads)"
        )
        XCTAssertEqual(
            BlastResultsDrawerTab.verificationSummary(for: result, subject: ""),
            BlastResultsDrawerTab.verificationSummary(for: result)
        )
    }

    // MARK: - BLAST-ESVIRITU-FIRST-WORD (BIO): the pane and the table say what a row was judged at

    /// A result judged at `basis` whose one read has a significant hit that matches the row, so it reads Not judged at
    /// `.rowTaxId` or `.names` and Supported at a species. With `significantHit` false its one read has no significant
    /// hit, and it reads Inconclusive at any basis (BLAST-BIO-UX should-fix 1).
    private func makeJudgedResult(
        judgedAt basis: BlastTaxonomyContext.Basis?, significantHit: Bool = true
    ) -> BlastVerificationResult {
        var result = BlastVerificationResult(
            taxonName: "Oxbow virus", taxId: 12345,
            readResults: [
                significantHit
                    ? BlastReadResult(id: "read_1", verdict: .verified, matchesQueriedTaxon: true)
                    : BlastReadResult(id: "read_1", verdict: .unverified)
            ],
            submittedAt: Date(), completedAt: Date(), rid: "TEST-RID", blastProgram: "blastn", database: "nt"
        )
        result.judgedAt = basis
        return result
    }

    /// A pane that shows a result judged at `basis`, laid out 600 pt wide.
    private func tab(judgedAt basis: BlastTaxonomyContext.Basis?, significantHit: Bool = true) -> BlastResultsDrawerTab {
        let tab = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        tab.presentationStyle = .verification
        tab.showResults(makeJudgedResult(judgedAt: basis, significantHit: significantHit), recordURL: nil)
        tab.layoutSubtreeIfNeeded()
        return tab
    }

    func testRowJudgedByNamesSaysSoBesideItsCounts() {
        // UX-BLAST-NOTAX item 5 moved these words: a row with no species lookup is not judged.
        let words = tab(judgedAt: .names).judgedAtLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Not judged: this row has no tax ID"), words)
        XCTAssertTrue(words.hasSuffix("Each read's best match is listed below."), words)
    }

    func testRowJudgedByItsOwnTaxIdSaysSoBesideItsCounts() {
        let words = tab(judgedAt: .rowTaxId).judgedAtLabel.stringValue
        XCTAssertTrue(words.hasPrefix("Not judged: without NCBI Taxonomy"), words)
        XCTAssertTrue(words.contains("if it does not list tax ID 12345"), words)
    }

    func testASpeciesLevelRowAndAnOlderRecordShowNoJudgedLine() {
        XCTAssertEqual(tab(judgedAt: .species).judgedAtLabel.stringValue, "")
        XCTAssertEqual(tab(judgedAt: nil).judgedAtLabel.stringValue, "", "a record from before the field shows no line")
    }

    /// The words shared the one-line summary label, which cuts its tail, so a person at an
    /// ordinary width never read them. They have a row of their own under the summary, and no row when there is nothing
    /// to say. At the lane head `judgedAtLabel` did not exist, so this test did not build.
    func testJudgedAtLineIsItsOwnLabelUnderTheSummary() {
        for basis in [BlastTaxonomyContext.Basis.rowTaxId, .names] {
            let pane = tab(judgedAt: basis)
            XCTAssertEqual(pane.judgedAtLabel.stringValue, basis.judgedAtWords(taxId: 12345))
            XCTAssertGreaterThan(pane.judgedAtLabel.frame.height, 0, "the line has a row of its own at 600 pt")
            XCTAssertEqual(pane.judgedAtLabel.maximumNumberOfLines, 0, "the line wraps and is never cut")
            XCTAssertFalse(pane.summaryLabel.stringValue.contains("Judged by"), "the summary label cuts its tail")
        }
        for basis in [BlastTaxonomyContext.Basis.species, nil] {
            XCTAssertEqual(tab(judgedAt: basis).judgedAtLabel.frame.height, 0, "no words, no row")
        }
        let judged = makeJudgedResult(judgedAt: .names)
        let contig = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        contig.showResults(judged, recordURL: nil)
        contig.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(contig.judgedAtLabel.frame.height, 0, "the verification style shows the row")
        contig.presentationStyle = .contigBlast
        contig.layoutSubtreeIfNeeded()
        XCTAssertEqual(contig.judgedAtLabel.frame.height, 0, "another presentation style shows no judged-at row")
    }

    /// BLAST-BIO-UX should-fix 1, red at `b77143ece`: a result judged at its own tax ID or by names showed "Not judged: ...
    /// Each read's best match is listed below" under an Inconclusive badge when no read had a significant hit, though nothing
    /// was withheld, no read has a best match and a rerun finds the same. The line belongs to the Not judged state, so a
    /// result with no significant hit shows the badge and no line, and one with a significant hit still shows both.
    func testAResultWithNoSignificantHitShowsNoJudgedLineUnderItsInconclusiveBadge() {
        for basis in [BlastTaxonomyContext.Basis.rowTaxId, .names] {
            let pane = tab(judgedAt: basis, significantHit: false)
            XCTAssertEqual(pane.confidenceLabel.stringValue, "Inconclusive")
            XCTAssertEqual(pane.judgedAtLabel.stringValue, "", "nothing was withheld, so there is no line to read")
            XCTAssertEqual(pane.judgedAtLabel.frame.height, 0, "no words, no row")

            let judged = tab(judgedAt: basis)
            XCTAssertEqual(judged.confidenceLabel.stringValue, "Not judged")
            XCTAssertEqual(judged.judgedAtLabel.stringValue, basis.judgedAtWords(taxId: 12345))
        }
    }

    /// UX-BLAST-NOTAX item 5 moved these words. A row judged at its own tax ID names the place that installs NCBI
    /// Taxonomy, the Databases tab of the Plugin Manager, since the app has no database manager, and the tax ID an older
    /// dump may lack. A row with no tax ID gets no verdict even with NCBI Taxonomy installed, so its line names no install.
    func testTheJudgedAtWordsNameALookupAsTheCauseAndTheDatabasesTabAsThePlace() {
        let rowTaxId = BlastTaxonomyContext.Basis.rowTaxId.judgedAtWords(taxId: 10407) ?? ""
        XCTAssertTrue(
            rowTaxId.contains(
                "Install NCBI Taxonomy in the Databases tab of the Plugin Manager, or update it if it does not list tax ID 10407, "
                    + "then run Verify with BLAST… again."
            ),
            rowTaxId
        )
        let names = BlastTaxonomyContext.Basis.names.judgedAtWords(taxId: 0) ?? ""
        XCTAssertFalse(names.contains("Install"), names)
        for words in [rowTaxId, names] {
            XCTAssertTrue(words.hasPrefix("Not judged: "), words)
            XCTAssertFalse(words.contains("database manager"), words)
        }
        XCTAssertNil(BlastTaxonomyContext.Basis.species.judgedAtWords(taxId: 10407))
    }

    func testExportNamesTheBasisOfEachRow() {
        func lastCells(_ basis: BlastTaxonomyContext.Basis?) -> [String] {
            var result = BlastVerificationResult(
                taxonName: "Oxbow virus", taxId: 0, readResults: [BlastReadResult(id: "read_1", verdict: .unverified)],
                submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "nt"
            )
            result.judgedAt = basis
            return BlastVerificationTableExport.tableContent(result: result, taxonomy: nil, separator: ",")
                .split(separator: "\n").map { String($0.split(separator: ",", omittingEmptySubsequences: false).last ?? "") }
        }
        XCTAssertEqual(lastCells(.names), ["Judged At", "names"])
        XCTAssertEqual(lastCells(.species), ["Judged At", "species"])
        XCTAssertEqual(lastCells(nil), ["Judged At", ""], "an older record has an empty cell")
    }

    /// Fix BLAST-FIX m2, ruling UX-BLAST-NOTAX items 7 and 8, red at `611610d57`: the Taxon Check read `supporting` and the
    /// archive's provenance gave counts with no confidence. A read of a result that was not judged reads `not judged`, and
    /// the provenance carries `confidence` `notJudged` beside the counts.
    func testANotJudgedResultExportsNotJudgedAndItsProvenanceSaysSo() throws {
        var result = BlastVerificationResult(
            taxonName: "Hepatitis B virus", taxId: 10407,
            readResults: [
                BlastReadResult(
                    id: "read_1", verdict: .verified, topHitOrganism: "Woolly monkey hepatitis B virus",
                    percentIdentity: 100, eValue: 1e-30, matchesQueriedTaxon: true
                ),
                BlastReadResult(id: "read_2", verdict: .unverified),
            ],
            submittedAt: Date(), completedAt: Date(), rid: "R", blastProgram: "blastn", database: "core_nt"
        )
        result.judgedAt = .rowTaxId
        let taxonCheck = BlastVerificationTableExport.tableContent(result: result, taxonomy: nil, separator: "\t")
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false)[13] }
        XCTAssertEqual(taxonCheck, ["not judged", "inconclusive"])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("not-judged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try BlastVerificationArchive.save(result, request: nil, in: folder, toolName: "lungfish-cli", toolKind: "cli")
        let sidecar = try String(contentsOf: URL(fileURLWithPath: archive.path + ".lungfish-provenance.json"), encoding: .utf8)
        XCTAssertTrue(sidecar.contains("notJudged"), sidecar)
    }

    /// A change of presentation style draws the shown result again and keeps its sample.
    func testARedrawForAnotherStyleKeepsTheSubject() {
        let tab = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        tab.showResults(makeResult(), recordURL: nil, subject: "S2")

        tab.presentationStyle = .contigBlast
        XCTAssertEqual(tab.summaryLabel.stringValue, "BLAST results for Oxbow virus (sample S2)")

        tab.presentationStyle = .verification
        XCTAssertTrue(tab.summaryLabel.stringValue.hasPrefix("BLAST for Oxbow virus (sample S2): "), tab.summaryLabel.stringValue)
    }

    /// Ruling BIO-BLAST-MATES Q2. Counts are fragments, and reads are the sequences sent.
    func testSummaryCountsFragmentsAndReads() {
        func fragment(_ id: String) -> BlastReadResult {
            BlastReadResult(
                id: id, verdict: .verified, matchesQueriedTaxon: true,
                otherMates: [BlastReadResult(id: id, verdict: .unverified)]
            )
        }
        func summary(_ rows: [BlastReadResult]) -> String {
            BlastResultsDrawerTab.verificationSummary(for: BlastVerificationResult(
                taxonName: "Human immunodeficiency virus 1", taxId: 11676, readResults: rows,
                submittedAt: Date(), completedAt: Date(), rid: "EGTB319K014", blastProgram: "blastn", database: "core_nt"
            ))
        }
        XCTAssertEqual(
            summary([fragment("SRR12486983.3484597")]),
            "BLAST for Human immunodeficiency virus 1: 1 supporting, 0 contradicting (1 fragment, 2 reads)"
        )
        XCTAssertEqual(
            summary([fragment("a"), fragment("b"), BlastReadResult(id: "c", verdict: .unverified)]),
            "BLAST for Human immunodeficiency virus 1: 2 supporting, 0 contradicting (3 fragments, 5 reads)"
        )
        XCTAssertEqual(
            summary([BlastReadResult(id: "c", verdict: .unverified), BlastReadResult(id: "d", verdict: .unverified)]),
            "BLAST for Human immunodeficiency virus 1: 0 supporting, 0 contradicting (2 reads)"
        )
    }
}
