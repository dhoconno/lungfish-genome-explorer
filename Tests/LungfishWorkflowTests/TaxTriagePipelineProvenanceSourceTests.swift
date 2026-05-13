import XCTest

final class TaxTriagePipelineProvenanceSourceTests: XCTestCase {
    private var pipelineSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift")
    }

    func testTaxTriagePipelineRecordsCanonicalRunProvenance() throws {
        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ProvenanceRecorder.shared.beginRun("))
        XCTAssertTrue(source.contains("ProvenanceRecorder.shared.recordStep("))
        XCTAssertTrue(source.contains("ProvenanceRecorder.shared.completeRun(runID, status: .completed)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.shared.save(runID: runID, to: profileAdjustedConfig.outputDirectory)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: $0, role: .output)"))
    }
}
