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

    func testInPlaceFASTQIngestionPreservesImportedCLIProvenanceAndAppendsOptimizationSteps() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQIngestionImportedCLIProvenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = temp.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let importedFASTQ = bundleURL.appendingPathComponent("Sample.fastq")
        let optimizedFASTQ = bundleURL.appendingPathComponent("Sample.fastq.gz")
        try "@r\nACGT\n+\n!!!!\n".write(to: importedFASTQ, atomically: true, encoding: .utf8)

        let sourceCLIOutput = temp.appendingPathComponent("cli-download.fastq")
        try "@r\nACGT\n+\n!!!!\n".write(to: sourceCLIOutput, atomically: true, encoding: .utf8)
        let sourceSidecarURL = ProvenanceRecorder.fileSidecarURL(for: sourceCLIOutput)
        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Download",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceCLIOutput.path])
        .output(sourceCLIOutput, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", sourceCLIOutput.path],
                outputs: [try ProvenanceFileDescriptor.file(url: sourceCLIOutput, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, toSidecar: sourceSidecarURL)
        try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(
            from: sourceCLIOutput,
            to: importedFASTQ
        )

        let importedRecord = ProvenanceRecorder.fileRecord(url: importedFASTQ, format: .fastq, role: .input)
        try? FileManager.default.removeItem(at: importedFASTQ)
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: optimizedFASTQ)

        let optimizationStep = StepExecution(
            toolName: "clumpify.sh",
            toolVersion: "test-bbtools",
            command: ["clumpify.sh", "in=\(importedFASTQ.path)", "out=\(optimizedFASTQ.path)"],
            inputs: [importedRecord],
            outputs: [ProvenanceRecorder.fileRecord(url: optimizedFASTQ, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 1.25
        )
        let result = FASTQIngestionResult(
            outputFile: optimizedFASTQ,
            wasClumpified: true,
            qualityBinning: .illumina4,
            originalFilenames: [importedFASTQ.lastPathComponent],
            originalSizeBytes: 15,
            finalSizeBytes: 4,
            pairingMode: .singleEnd,
            provenanceSteps: [optimizationStep]
        )
        let config = FASTQIngestionConfig(
            inputFiles: [importedFASTQ],
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
            originalFilenames: [importedFASTQ.lastPathComponent],
            ingestionDate: Date(timeIntervalSince1970: 1),
            originalSizeBytes: 15
        )

        try await FASTQIngestionService.testingSaveInPlaceIngestionProvenance(
            result: result,
            config: config,
            ingestion: ingestion
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(envelope.steps.map(\.toolName), ["lungfish-cli", "lungfish-app", "clumpify.sh", "lungfish-app"])
        XCTAssertEqual(envelope.output?.path, FASTQMetadataStore.metadataURL(for: optimizedFASTQ).path)
        XCTAssertTrue(envelope.outputs.contains { $0.path == optimizedFASTQ.path })
        XCTAssertFalse(envelope.files.contains { $0.role == .output && $0.path == importedFASTQ.path })
        XCTAssertFalse(envelope.files.contains { $0.role == .output && $0.path == sourceCLIOutput.path })

        let legacy = try XCTUnwrap(ProvenanceRecorder.load(from: bundleURL))
        XCTAssertEqual(legacy.steps.map(\.toolName), ["lungfish-cli", "lungfish-app", "clumpify.sh", "lungfish-app"])
    }
}
