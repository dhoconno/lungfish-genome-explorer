import XCTest
@testable import LungfishKit
@testable import LungfishCore
@testable import LungfishWorkflow

/// REC-03: the BLAST results table's CSV/TSV export used to write only the
/// payload with `content.write(to:atomically:encoding:)`, with no provenance
/// sidecar at all. Asserts `writeExportFile` now writes one atomically,
/// through `ScientificFileExportProvenance`.
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

    func testWriteExportFileWritesPayloadAndProvenanceSidecar() throws {
        let tab = BlastResultsDrawerTab(frame: .zero)
        let result = makeResult()

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let outputURL = outputDirectory.appendingPathComponent("blast-results.csv")

        tab.writeExportFile(result: result, to: outputURL, separator: ",")

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app blast verification table export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
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
