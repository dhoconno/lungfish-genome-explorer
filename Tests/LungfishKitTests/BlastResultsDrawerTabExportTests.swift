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
}
