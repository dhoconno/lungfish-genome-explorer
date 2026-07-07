import XCTest

final class EsVirituProvenanceSourceTests: XCTestCase {
    private var appDelegateSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
    }

    private var pipelineSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift")
    }

    func testAppDelegateWritesRootProvenanceForSingleAndBatchEsVirituResults() throws {
        let source = combinedAppDelegateSource()
        let callCount = source.components(separatedBy: "MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance").count - 1

        XCTAssertGreaterThanOrEqual(callCount, 2)
        XCTAssertTrue(source.contains("MetagenomicsBatchResultStore.saveEsViritu(manifest, to: esvBatchRoot)"))
        XCTAssertTrue(source.contains("MetagenomicsBatchResultStore.saveEsViritu(manifest, to: batchRoot)"))
    }

    func testEsVirituPipelineRecordsChecksummedFilesAtFinalOutputPaths() throws {
        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: config.detectionOutputURL, format: .text, role: .output)"))
        XCTAssertFalse(source.contains("FileRecord(path: url.path, format: .fastq, role: .input)"))
        XCTAssertFalse(source.contains("FileRecord(path: config.detectionOutputURL.path, format: .text, role: .output)"))
    }

    func testEsVirituSidecarFailureRecordsFailedWrapperStepInSource() throws {
        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("} catch let sidecarError {\n            await provenanceRecorder.recordStep("))
        XCTAssertTrue(source.contains(#"toolName: "Lungfish EsViritu Result Sidecar""#))
        XCTAssertTrue(source.contains("exitCode: 1,\n                wallTime: Date().timeIntervalSince(sidecarSaveStart),\n                stderr: sidecarError.localizedDescription"))
    }
}
