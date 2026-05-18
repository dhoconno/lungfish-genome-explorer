import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTImportWorkflowTests: XCTestCase {
    func testImportWritesRootAndFocusedBundleProvenance() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("fastq_pass", isDirectory: true)
        let outputURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let chunkURL = try writeONTChunk(
            under: sourceURL,
            barcode: "barcode01",
            filename: "chunk_0.fastq",
            readID: "read1"
        )

        let workflow = ONTImportWorkflow()
        let result = try await workflow.importDirectory(
            config: ONTImportConfig(
                sourceDirectory: sourceURL,
                outputDirectory: outputURL,
                maxConcurrentBarcodes: 1
            ),
            context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
        ) { _, _ in }

        let rootEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputURL))
        XCTAssertEqual(rootEnvelope.workflowName, "lungfish fastq import-ont")
        XCTAssertEqual(rootEnvelope.toolName, "lungfish fastq import-ont")
        XCTAssertEqual(rootEnvelope.exitStatus, 0)
        XCTAssertNotNil(rootEnvelope.wallTimeSeconds)
        XCTAssertTrue(rootEnvelope.argv.contains(sourceURL.path))

        let bundleURL = try XCTUnwrap(result.importResult.bundleURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))

        let payloadURL = bundleURL.appendingPathComponent("chunks/chunk_0.fastq")
        let focusedURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(for: payloadURL, inBundle: bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: focusedURL.path))
    }

    func testProvenanceDescriptorsUseOriginalInputsAndFinalOutputs() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("fastq_pass", isDirectory: true)
        let outputURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let chunk0 = try writeONTChunk(
            under: sourceURL,
            barcode: "barcode01",
            filename: "chunk_0.fastq",
            readID: "read1"
        )
        let chunk1 = try writeONTChunk(
            under: sourceURL,
            barcode: "barcode01",
            filename: "chunk_1.fastq",
            readID: "read2"
        )

        let workflow = ONTImportWorkflow()
        _ = try await workflow.importDirectory(
            config: ONTImportConfig(
                sourceDirectory: sourceURL,
                outputDirectory: outputURL,
                maxConcurrentBarcodes: 1
            ),
            context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
        ) { _, _ in }

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputURL))
        let inputByPath = Dictionary(uniqueKeysWithValues: envelope.files
            .filter { $0.role == .input }
            .map { ($0.path, $0) })
        XCTAssertNotNil(inputByPath[chunk0.path]?.checksumSHA256)
        XCTAssertNotNil(inputByPath[chunk0.path]?.fileSize)
        XCTAssertNotNil(inputByPath[chunk1.path]?.checksumSHA256)
        XCTAssertNotNil(inputByPath[chunk1.path]?.fileSize)

        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(outputURL.appendingPathComponent(DemultiplexManifest.filename).path))
        XCTAssertTrue(outputPaths.contains(outputURL.appendingPathComponent("barcode01.lungfishfastq/chunks/chunk_0.fastq").path))
        XCTAssertTrue(outputPaths.contains(outputURL.appendingPathComponent("barcode01.lungfishfastq/chunks/chunk_1.fastq").path))
        XCTAssertFalse(outputPaths.contains(chunk0.path), "Original ONT chunks are inputs, not final outputs.")

        for output in envelope.outputs {
            XCTAssertNotNil(output.checksumSHA256, output.path)
            XCTAssertNotNil(output.fileSize, output.path)
        }
    }

    func testProvenanceWriteFailureRollsBackCreatedBundlesAndManifest() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("fastq_pass", isDirectory: true)
        let outputURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try writeONTChunk(
            under: sourceURL,
            barcode: "barcode01",
            filename: "chunk_0.fastq",
            readID: "read1"
        )

        let workflow = ONTImportWorkflow(provenanceWriter: { _, _ in
            throw NSError(domain: "ONTImportWorkflowTests", code: 42)
        })

        do {
            _ = try await workflow.importDirectory(
                config: ONTImportConfig(
                    sourceDirectory: sourceURL,
                    outputDirectory: outputURL,
                    maxConcurrentBarcodes: 1
                ),
                context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
            ) { _, _ in }
            XCTFail("Expected provenance writer failure to abort the import.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent("barcode01.lungfishfastq").path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent(DemultiplexManifest.filename).path
            ))
        }
    }

    private func makeContext(sourceURL: URL, outputURL: URL) -> ONTImportWorkflow.CommandContext {
        ONTImportWorkflow.CommandContext(
            caller: .cli,
            workflowName: "lungfish fastq import-ont",
            workflowVersion: "test-workflow",
            toolName: "lungfish fastq import-ont",
            toolVersion: "test-tool",
            argv: ["lungfish", "fastq", "import-ont", sourceURL.path, "--output", outputURL.path],
            durableReplayArgv: ["lungfish", "fastq", "import-ont", sourceURL.path, "--output", outputURL.path],
            reproducibleCommand: "lungfish fastq import-ont \(sourceURL.path) --output \(outputURL.path)",
            explicitOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL)
            ],
            defaultOptions: [
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(4),
                "useVirtualConcatenation": .boolean(true)
            ],
            resolvedOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(1),
                "useVirtualConcatenation": .boolean(true),
                "caller": .string("cli")
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: "test",
                executablePath: "/usr/bin/lungfish",
                processIdentifier: 1,
                operatingSystemVersion: "macOS test",
                architecture: "arm64"
            )
        )
    }

    @discardableResult
    private func writeONTChunk(
        under sourceURL: URL,
        barcode: String,
        filename: String,
        readID: String
    ) throws -> URL {
        let barcodeURL = sourceURL.appendingPathComponent(barcode, isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeURL, withIntermediateDirectories: true)
        let chunkURL = barcodeURL.appendingPathComponent(filename)
        let content = """
        @\(readID) runid=abc123 flow_cell_id=FBC00001 sample_id=ONT05 barcode=\(barcode) basecall_model_version_id=dna_r10.4.1_sup@v4.3.0
        ACGTACGT
        +
        IIIIIIII

        """
        try content.write(to: chunkURL, atomically: true, encoding: .utf8)
        return chunkURL
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTImportWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
