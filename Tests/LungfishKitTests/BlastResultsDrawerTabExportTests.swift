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
