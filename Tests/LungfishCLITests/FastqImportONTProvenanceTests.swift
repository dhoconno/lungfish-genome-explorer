import ArgumentParser
import XCTest
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqImportONTProvenanceTests: XCTestCase {
    func testImportONTRecordsCLIContextDefaultsRuntimeAndFinalOutputs() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("fastq_pass", isDirectory: true)
        let outputURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try writeONTChunk(under: sourceURL, barcode: "barcode01", filename: "chunk_0.fastq")

        let command = try FastqImportONTSubcommand.parse([
            sourceURL.path,
            "--output", outputURL.path,
            "--concurrency", "1"
        ])
        try await command.run()

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputURL))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.toolName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.argv, [
            "lungfish", "fastq", "import-ont",
            sourceURL.path,
            "--output", outputURL.path,
            "--concurrency", "1"
        ])
        XCTAssertEqual(envelope.options.defaults["includeUnclassified"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.defaults["concurrency"]?.integerValue, 4)
        XCTAssertEqual(envelope.options.resolvedDefaults["includeUnclassified"]?.booleanValue, false)
        XCTAssertEqual(envelope.options.resolvedDefaults["concurrency"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"]?.stringValue, "cli")
        XCTAssertFalse(envelope.runtimeIdentity.executablePath.isEmpty)

        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(outputURL.appendingPathComponent(DemultiplexManifest.filename).path))
        XCTAssertTrue(outputPaths.contains(outputURL.appendingPathComponent("barcode01.lungfishfastq/chunks/chunk_0.fastq").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputURL.appendingPathComponent("barcode01.lungfishfastq/.lungfish-provenance.json").path
        ))
    }

    @discardableResult
    private func writeONTChunk(
        under sourceURL: URL,
        barcode: String,
        filename: String
    ) throws -> URL {
        let barcodeURL = sourceURL.appendingPathComponent(barcode, isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeURL, withIntermediateDirectories: true)
        let chunkURL = barcodeURL.appendingPathComponent(filename)
        let content = """
        @read1 runid=abc123 flow_cell_id=FBC00001 sample_id=ONT05 barcode=\(barcode) basecall_model_version_id=dna_r10.4.1_sup@v4.3.0
        ACGTACGT
        +
        IIIIIIII

        """
        try content.write(to: chunkURL, atomically: true, encoding: .utf8)
        return chunkURL
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqImportONTProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
