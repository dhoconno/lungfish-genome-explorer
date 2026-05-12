import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class FASTQIngestionProvenanceTests: XCTestCase {
    func testInPlaceFASTQIngestionWritesProvenanceForFinalBundlePayload() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQIngestionProvenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let inputURL = temp.appendingPathComponent("raw.fastq")
        try "@r\nACGT\n+\n!!!!\n".write(to: inputURL, atomically: true, encoding: .utf8)

        let bundleURL = projectURL.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let outputURL = bundleURL.appendingPathComponent("Sample.fastq.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: outputURL)

        let step = StepExecution(
            toolName: "clumpify.sh",
            toolVersion: "test-bbtools",
            command: ["clumpify.sh", "in=\(inputURL.path)", "out=\(outputURL.path)"],
            inputs: [ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 1.25
        )
        let result = FASTQIngestionResult(
            outputFile: outputURL,
            wasClumpified: true,
            qualityBinning: .illumina4,
            originalFilenames: [inputURL.lastPathComponent],
            originalSizeBytes: 15,
            finalSizeBytes: 4,
            pairingMode: .singleEnd,
            provenanceSteps: [step]
        )
        let config = FASTQIngestionConfig(
            inputFiles: [inputURL],
            outputDirectory: bundleURL,
            threads: 4,
            deleteOriginals: true,
            qualityBinning: .illumina4,
            skipClumpify: false
        )
        let ingestion = IngestionMetadata(
            isClumpified: true,
            isCompressed: true,
            pairingMode: .singleEnd,
            qualityBinning: QualityBinningScheme.illumina4.rawValue,
            originalFilenames: [inputURL.lastPathComponent],
            ingestionDate: Date(timeIntervalSince1970: 1),
            originalSizeBytes: 15
        )

        try await FASTQIngestionService.testingSaveInPlaceIngestionProvenance(
            result: result,
            config: config,
            ingestion: ingestion
        )

        let run = try XCTUnwrap(ProvenanceRecorder.load(from: bundleURL))
        XCTAssertEqual(run.name, "FASTQ Ingestion")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.steps.map(\.toolName), ["clumpify.sh", "lungfish-app"])
        XCTAssertEqual(run.parameters["qualityBinning"]?.stringValue, "illumina4")
        XCTAssertEqual(run.allOutputFiles.map(\.path).last, FASTQMetadataStore.metadataURL(for: outputURL).path)
    }
}
