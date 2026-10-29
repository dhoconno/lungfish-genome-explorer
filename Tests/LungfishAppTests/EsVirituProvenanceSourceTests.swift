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

    /// The inputs of an EsViritu step come from `EsVirituPipeline.stepInputRecords(for:)` since DB-IDENTITY (3.1,
    /// `0373e8cc5`), which also adds the database as a reference input. The helper sits in this file.
    private var stepInputRecordsSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline+DatabaseReference.swift")
    }

    func testEsVirituPipelineRecordsChecksummedFilesAtFinalOutputPaths() throws {
        let source = try readRepositorySource(pipelineSourceURL)
        let inputSource = try readRepositorySource(stepInputRecordsSourceURL)

        // The reads. The helper that builds the inputs of the failed and the finished step hashes each read
        // through the recorder at the path the config names, and the unhashed form stays out of the pipeline.
        XCTAssertTrue(inputSource.contains("ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)"))
        XCTAssertFalse(source.contains("FileRecord(path: url.path, format: .fastq, role: .input)"))

        // The output record stays in the pipeline file, at the final path the config names.
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: config.detectionOutputURL, format: .text, role: .output)"))
        XCTAssertFalse(source.contains("FileRecord(path: config.detectionOutputURL.path, format: .text, role: .output)"))
    }

    func testEsVirituSidecarFailureRecordsFailedWrapperStepInSource() throws {
        let source = try readRepositorySource(pipelineSourceURL)

        XCTAssertTrue(source.contains("} catch let sidecarError {\n            await provenanceRecorder.recordStep("))
        XCTAssertTrue(source.contains(#"toolName: "Lungfish EsViritu Result Sidecar""#))
        XCTAssertTrue(source.contains("exitCode: 1,\n                wallTime: sidecarSaveClock.elapsed,\n                stderr: sidecarError.localizedDescription"))
    }
}
