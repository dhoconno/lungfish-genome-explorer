import XCTest
import LungfishTestSupport

/// The EsViritu pipeline is the one `lungfish-cli esviritu detect` runs, so its two source pins stay.
/// The three pins on the app delegate's in-process launch retired with that launch in Phase 2.9
/// (E14, lane A12).
final class EsVirituProvenanceSourceTests: XCTestCase {
    private var pipelineSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift")
    }

    func testEsVirituPipelineRecordsChecksummedFilesAtFinalOutputPaths() throws {
        let source = try readRepositorySource(pipelineSourceURL)

        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: config.detectionOutputURL, format: .text, role: .output)"))
        XCTAssertFalse(source.contains("FileRecord(path: url.path, format: .fastq, role: .input)"))
        XCTAssertFalse(source.contains("FileRecord(path: config.detectionOutputURL.path, format: .text, role: .output)"))
    }

    func testEsVirituSidecarFailureRecordsFailedWrapperStepInSource() throws {
        let source = try readRepositorySource(pipelineSourceURL)

        XCTAssertTrue(source.contains("} catch let sidecarError {\n            await provenanceRecorder.recordStep("))
        XCTAssertTrue(source.contains(#"toolName: "Lungfish EsViritu Result Sidecar""#))
        XCTAssertTrue(source.contains("exitCode: 1,\n                wallTime: sidecarSaveClock.elapsed,\n                stderr: sidecarError.localizedDescription"))
    }
}
