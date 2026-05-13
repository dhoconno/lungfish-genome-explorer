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
        let source = try String(contentsOf: appDelegateSourceURL, encoding: .utf8)
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
}
