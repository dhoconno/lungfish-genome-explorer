import Foundation
import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class ONTImportWorkflowTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-workflow-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testImportWritesRootAndFocusedBundleProvenance() async throws {
        let sourceURL = try makeONTSource(barcodeChunks: ["barcode01": ["chunk_0.fastq"]])
        let outputURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let workflow = ONTImportWorkflow()

        let result = try await workflow.importDirectory(
            config: ONTImportConfig(
                sourceDirectory: sourceURL,
                outputDirectory: outputURL,
                maxConcurrentBarcodes: 1
            ),
            context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
        ) { _, _ in }

        let rootEnvelope = try readEnvelope(outputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
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

        let copiedChunkURL = bundleURL
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent("chunk_0.fastq")
        let focusedURL = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(
            for: copiedChunkURL,
            inBundle: bundleURL
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: focusedURL.path))
    }

    func testProvenanceDescriptorsUseOriginalInputsAndFinalOutputs() async throws {
        let sourceURL = try makeONTSource(barcodeChunks: [
            "barcode01": ["chunk_0.fastq", "chunk_1.fastq"],
        ])
        let outputURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let workflow = ONTImportWorkflow()

        let result = try await workflow.importDirectory(
            config: ONTImportConfig(
                sourceDirectory: sourceURL,
                outputDirectory: outputURL,
                maxConcurrentBarcodes: 1
            ),
            context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
        ) { _, _ in }

        let envelope = try readEnvelope(outputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let originalChunkURLs = [
            sourceURL.appendingPathComponent("barcode01").appendingPathComponent("chunk_0.fastq"),
            sourceURL.appendingPathComponent("barcode01").appendingPathComponent("chunk_1.fastq"),
        ]
        for chunkURL in originalChunkURLs {
            let descriptor = try XCTUnwrap(envelope.files.first {
                $0.path == canonicalPath(chunkURL) && $0.role == .input
            }, "Missing input \(canonicalPath(chunkURL)); files:\n\(envelope.files.map(\.path).sorted().joined(separator: "\n"))")
            XCTAssertNotNil(descriptor.checksumSHA256)
            XCTAssertNotNil(descriptor.fileSize)
        }

        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(canonicalPath(outputURL.appendingPathComponent(DemultiplexManifest.filename))))

        let bundleURL = try XCTUnwrap(result.importResult.bundleURLs.first)
        let copiedChunkURLs = [
            bundleURL.appendingPathComponent("chunks").appendingPathComponent("chunk_0.fastq"),
            bundleURL.appendingPathComponent("chunks").appendingPathComponent("chunk_1.fastq"),
        ]
        for copiedChunkURL in copiedChunkURLs {
            let descriptor = try XCTUnwrap(envelope.outputs.first { $0.path == canonicalPath(copiedChunkURL) })
            XCTAssertNotNil(descriptor.checksumSHA256)
            XCTAssertNotNil(descriptor.fileSize)
        }
        for originalChunkURL in originalChunkURLs {
            XCTAssertFalse(outputPaths.contains(canonicalPath(originalChunkURL)))
        }
    }

    func testProvenanceWriteFailureRollsBackCreatedBundlesAndManifest() async throws {
        let sourceURL = try makeONTSource(barcodeChunks: ["barcode01": ["chunk_0.fastq"]])
        let outputURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let workflow = ONTImportWorkflow { _, _ in
            throw NSError(domain: "ONTImportWorkflowTests", code: 42)
        }

        do {
            _ = try await workflow.importDirectory(
                config: ONTImportConfig(
                    sourceDirectory: sourceURL,
                    outputDirectory: outputURL,
                    maxConcurrentBarcodes: 1
                ),
                context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
            ) { _, _ in }
            XCTFail("Expected provenance writer failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ONTImportWorkflowTests")
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent("barcode01.lungfishfastq").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(DemultiplexManifest.filename).path
        ))
    }

    func testImporterFailureRollsBackPreviouslyCreatedBundles() async throws {
        let sourceURL = try makeONTSource(barcodeChunks: ["barcode01": ["chunk_0.fastq"]])
        let invalidBarcodeURL = sourceURL.appendingPathComponent("barcode02", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidBarcodeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: invalidBarcodeURL.appendingPathComponent("chunk_0.fastq", isDirectory: true),
            withIntermediateDirectories: true
        )
        let outputURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let workflow = ONTImportWorkflow()

        do {
            _ = try await workflow.importDirectory(
                config: ONTImportConfig(
                    sourceDirectory: sourceURL,
                    outputDirectory: outputURL,
                    maxConcurrentBarcodes: 1
                ),
                context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
            ) { _, _ in }
            XCTFail("Expected importer failure")
        } catch {
            XCTAssertFalse(error is ONTImportWorkflow.ImportError)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent("barcode01.lungfishfastq").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent("barcode02.lungfishfastq").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent(DemultiplexManifest.filename).path
        ))
    }

    func testPreflightRefusesExistingBundleWithoutDeletingIt() async throws {
        let sourceURL = try makeONTSource(barcodeChunks: ["barcode01": ["chunk_0.fastq"]])
        let outputURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let existingBundleURL = outputURL.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: existingBundleURL, withIntermediateDirectories: true)
        let sentinelURL = existingBundleURL.appendingPathComponent("sentinel.txt")
        try "do not delete".write(to: sentinelURL, atomically: true, encoding: .utf8)
        let workflow = ONTImportWorkflow()

        do {
            _ = try await workflow.importDirectory(
                config: ONTImportConfig(
                    sourceDirectory: sourceURL,
                    outputDirectory: outputURL,
                    maxConcurrentBarcodes: 1
                ),
                context: makeContext(sourceURL: sourceURL, outputURL: outputURL)
            ) { _, _ in }
            XCTFail("Expected output conflict")
        } catch let error as ONTImportWorkflow.ImportError {
            guard case .outputAlreadyExists(let paths) = error else {
                return XCTFail("Expected outputAlreadyExists, got \(error)")
            }
            XCTAssertEqual(paths, [existingBundleURL.path])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    private func makeContext(sourceURL: URL, outputURL: URL) -> ONTImportWorkflow.CommandContext {
        let argv = [
            "lungfish", "fastq", "import-ont",
            sourceURL.path, "--output", outputURL.path, "--concurrency", "1",
        ]
        return ONTImportWorkflow.CommandContext(
            caller: .cli,
            workflowName: "lungfish fastq import-ont",
            workflowVersion: "test-version",
            toolName: "lungfish fastq import-ont",
            toolVersion: "test-version",
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.joined(separator: " "),
            explicitOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "concurrency": .integer(1),
            ],
            defaultOptions: [
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(4),
                "useVirtualConcatenation": .boolean(true),
            ],
            resolvedOptions: [
                "input": .file(sourceURL),
                "output": .file(outputURL),
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(1),
                "useVirtualConcatenation": .boolean(true),
                "caller": .string("cli"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: "test-version",
                executablePath: "/tmp/lungfish-test",
                processIdentifier: 123,
                operatingSystemVersion: "test-os",
                architecture: "test-arch"
            )
        )
    }

    private func makeONTSource(barcodeChunks: [String: [String]]) throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("fastq_pass", isDirectory: true)
        for (barcode, filenames) in barcodeChunks {
            let barcodeURL = sourceURL.appendingPathComponent(barcode, isDirectory: true)
            try FileManager.default.createDirectory(at: barcodeURL, withIntermediateDirectories: true)
            for filename in filenames {
                try fastqText(readID: "\(barcode)-\(filename)")
                    .write(to: barcodeURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            }
        }
        return sourceURL
    }

    private func fastqText(readID: String) -> String {
        """
        @\(readID) runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01 basecall_model_version_id=dorado-test
        ACGT
        +
        !!!!

        """
    }

    private func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        let data = try Data(contentsOf: url)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
