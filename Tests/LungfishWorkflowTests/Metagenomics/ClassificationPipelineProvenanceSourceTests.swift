import XCTest

final class ClassificationPipelineProvenanceSourceTests: XCTestCase {
    private var pipelineSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift")
    }

    func testKraken2ProvenanceRecordsChecksummedFiles() throws {
        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: url"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: effectiveConfig.reportURL, format: .text, role: .report)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: effectiveConfig.outputURL, format: .text, role: .output)"))
        XCTAssertFalse(source.contains("FileRecord(path: effectiveConfig.reportURL.path, format: .text, role: .report)"))
        XCTAssertFalse(source.contains("FileRecord(path: effectiveConfig.outputURL.path, format: .text, role: .output)"))
    }

    func testBrackenFailedOutputIsOnlyRecordedWhenProduced() throws {
        let source = try String(contentsOf: pipelineSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("fm.fileExists(atPath: effectiveConfig.brackenURL.path)"))
        XCTAssertTrue(source.contains("ProvenanceRecorder.fileRecord(url: effectiveConfig.brackenURL, format: .text, role: .output)"))
        XCTAssertFalse(source.contains("FileRecord(path: effectiveConfig.brackenURL.path, format: .text, role: .output)"))
    }
}
