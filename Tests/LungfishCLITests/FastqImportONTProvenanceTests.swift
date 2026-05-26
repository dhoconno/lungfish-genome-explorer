import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI
import XCTest

final class FastqImportONTProvenanceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-import-ont-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testCLIImportONTDelegatesToWorkflowProvenance() async throws {
        let sourceURL = try makeONTSource()
        let outputURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let command = try FastqImportONTSubcommand.parse([
            sourceURL.path,
            "--output", outputURL.path,
            "--concurrency", "1",
        ])

        try await command.run()

        let envelope = try readEnvelope(outputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.toolName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.argv, [
            "lungfish", "fastq", "import-ont",
            sourceURL.path, "--output", outputURL.path, "--concurrency", "1",
        ])
        XCTAssertEqual(envelope.options.defaults["includeUnclassified"], .boolean(false))
        XCTAssertEqual(envelope.options.defaults["concurrency"], .integer(4))
        XCTAssertEqual(envelope.options.resolvedDefaults["includeUnclassified"], .boolean(false))
        XCTAssertEqual(envelope.options.resolvedDefaults["concurrency"], .integer(1))
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("cli"))
        XCTAssertFalse(envelope.runtimeIdentity.executablePath.isEmpty)

        let manifestURL = outputURL.appendingPathComponent(DemultiplexManifest.filename)
        let bundleURL = outputURL.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        let copiedChunkURL = outputURL
            .appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
            .appendingPathComponent("chunks")
            .appendingPathComponent("chunk_0.fastq")
        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(canonicalPath(manifestURL)))
        XCTAssertTrue(outputPaths.contains(canonicalPath(bundleURL)))
        XCTAssertFalse(outputPaths.contains(canonicalPath(copiedChunkURL)))

        let bundleEnvelope = try readEnvelope(bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertTrue(
            bundleEnvelope.outputs.contains { $0.path == canonicalPath(copiedChunkURL) },
            "Missing child bundle output \(canonicalPath(copiedChunkURL)); outputs:\n\(bundleEnvelope.outputs.map(\.path).sorted().joined(separator: "\n"))"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        ))
    }

    func testCLIImportONTFlattenedStorageRecordsProvenanceAndSinglePayload() async throws {
        let sourceURL = try makeONTSource()
        let outputURL = tempDir.appendingPathComponent("flattened-project", isDirectory: true)
        let command = try FastqImportONTSubcommand.parse([
            sourceURL.path,
            "--output", outputURL.path,
            "--concurrency", "1",
            "--storage-mode", "flattened",
        ])

        try await command.run()

        let envelope = try readEnvelope(outputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.options.resolvedDefaults["storageMode"], .string("flattened"))
        XCTAssertEqual(envelope.options.resolvedDefaults["useVirtualConcatenation"], .boolean(false))
        XCTAssertTrue(envelope.argv.contains("--storage-mode"))
        XCTAssertTrue(envelope.argv.contains("flattened"))

        let bundleURL = outputURL.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        let payloadURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: payloadURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("source-files.json").path
        ))
    }

    func testCLIImportONTCopiesExistingFASTQBundleAtomically() async throws {
        let sourceBundleURL = try makeExistingChunkedFASTQBundle()
        let outputURL = tempDir.appendingPathComponent("bundle-copy-project", isDirectory: true)
        let command = try FastqImportONTSubcommand.parse([
            sourceBundleURL.path,
            "--output", outputURL.path,
        ])

        try await command.run()

        let copiedBundleURL = outputURL.appendingPathComponent(sourceBundleURL.lastPathComponent, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedBundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copiedBundleURL.appendingPathComponent("source-files.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copiedBundleURL.appendingPathComponent("chunks/chunk_0.fastq").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copiedBundleURL.appendingPathComponent("chunks/chunk_1.fastq").path
        ))

        let resolvedURLs = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: copiedBundleURL))
        XCTAssertEqual(resolvedURLs.map(\.lastPathComponent).sorted(), ["chunk_0.fastq", "chunk_1.fastq"])

        let envelope = try readEnvelope(copiedBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.toolName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["sourceKind"], .string("existing-fastq-bundle"))
        XCTAssertTrue(envelope.argv.contains(sourceBundleURL.path))
        XCTAssertTrue(envelope.argv.contains(outputURL.path))

        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(canonicalPath(copiedBundleURL.appendingPathComponent("chunks/chunk_0.fastq"))))
        XCTAssertTrue(outputPaths.contains(canonicalPath(copiedBundleURL.appendingPathComponent("chunks/chunk_1.fastq"))))
        XCTAssertTrue(outputPaths.contains(canonicalPath(copiedBundleURL.appendingPathComponent("preview.fastq"))))
        XCTAssertFalse(
            outputPaths.contains {
                $0.hasSuffix("barcode08.lungfishfastq.lungfishfastq/preview.fastq")
            },
            "Existing FASTQ bundles must be copied atomically, not re-imported from preview.fastq"
        )
    }

    func testCLIImportONTOptimizeStorageRequiresFlattenedStorage() async throws {
        let command = try FastqImportONTSubcommand.parse([
            "/tmp/missing-fastq-pass",
            "--output", tempDir.appendingPathComponent("project").path,
            "--optimize-storage",
        ])

        do {
            try await command.run()
            XCTFail("Expected validation error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--storage-mode flattened"))
        }
    }

    private func makeONTSource() throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("fastq_pass", isDirectory: true)
        let barcodeURL = sourceURL.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeURL, withIntermediateDirectories: true)
        try """
        @read1 runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01 basecall_model_version_id=dorado-test
        ACGT
        +
        !!!!

        """.write(to: barcodeURL.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        return sourceURL
    }

    private func makeExistingChunkedFASTQBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunksURL = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)

        let chunk0 = chunksURL.appendingPathComponent("chunk_0.fastq")
        let chunk1 = chunksURL.appendingPathComponent("chunk_1.fastq")
        try """
        @read1 barcode=barcode08
        ACGT
        +
        IIII

        """.write(to: chunk0, atomically: true, encoding: .utf8)
        try """
        @read2 barcode=barcode08
        TGCA
        +
        IIII

        """.write(to: chunk1, atomically: true, encoding: .utf8)
        try """
        @preview-read barcode=barcode08
        ACGT
        +
        IIII

        """.write(to: bundleURL.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)

        let manifest = FASTQSourceFileManifest(files: [
            .init(filename: "chunks/chunk_0.fastq", originalPath: chunk0.path, sizeBytes: fileSize(chunk0), isSymlink: false),
            .init(filename: "chunks/chunk_1.fastq", originalPath: chunk1.path, sizeBytes: fileSize(chunk1), isSymlink: false),
        ])
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        let data = try Data(contentsOf: url)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
