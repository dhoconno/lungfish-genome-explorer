import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class PBAAClusteringPipelineTests: XCTestCase {
    func testPipelineImportsPassedFastaAsReferenceBundleAndWritesProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let passed = raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
            try ">cluster1\nACGT\n".write(to: passed, atomically: true, encoding: .utf8)
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        let output = root.appendingPathComponent("out", isDirectory: true)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: output,
            outputName: "sample",
            threads: 4,
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 2"
        )

        let result = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)

        XCTAssertEqual(result.referenceBundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.referenceBundleURL.path))
        XCTAssertEqual(result.passedConsensusFASTAURL.lastPathComponent, "sample_passed_cluster_sequences.fasta")

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result.referenceBundleURL))
        XCTAssertEqual(envelope.workflowName, "pbAA Amplicon Clustering")
        XCTAssertEqual(envelope.workflowVersion, PBAAContainerPins.workflowSchemaVersion)
        XCTAssertEqual(envelope.argv, [
            "lungfish", "fastq", "pbaa-cluster",
            reads.standardizedFileURL.path,
            "--guide", guide.standardizedFileURL.path,
            "--output-dir", output.standardizedFileURL.path,
            "--output-name", "sample",
            "--threads", "4",
            "--seed", "7",
            "--extra-args", "--min-cluster-read-count 2",
        ])
        XCTAssertEqual(envelope.runtimeIdentity.containerImage, PBAAContainerPins.pbaa.reference)
        XCTAssertEqual(envelope.runtimeIdentity.containerDigest, PBAAContainerPins.pbaa.expectedDigest)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.explicit["extraArguments"], .array([.string("--min-cluster-read-count"), .string("2")]))

        let manifest = try BundleManifest.load(from: result.referenceBundleURL)
        let genomePath = try XCTUnwrap(manifest.genome?.path)
        let finalPayloadURL = result.referenceBundleURL.appendingPathComponent(genomePath)
        XCTAssertTrue(envelope.outputs.contains { $0.path == finalPayloadURL.path })
    }

    func testPipelineFailsWhenPassedFastaIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta").path,
                contents: Data()
            )
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "sample"
        )

        do {
            _ = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)
            XCTFail("Expected empty passed FASTA failure")
        } catch PBAAClusteringError.emptyPassedConsensusFASTA(let url) {
            XCTAssertEqual(url.lastPathComponent, "sample_passed_cluster_sequences.fasta")
        }
    }
}

private struct StubPBAANextflowRunner: PBAANextflowRunning {
    let handler: @Sendable (PBAAClusteringRunRequest, URL) async throws -> PBAANextflowRunResult

    func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult {
        try await handler(request, workflowDirectory)
    }
}
