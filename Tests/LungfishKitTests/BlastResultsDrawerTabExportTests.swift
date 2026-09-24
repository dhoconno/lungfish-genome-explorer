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
}
