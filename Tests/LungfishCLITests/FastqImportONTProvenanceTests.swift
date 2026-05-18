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
        let copiedChunkURL = outputURL
            .appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
            .appendingPathComponent("chunks")
            .appendingPathComponent("chunk_0.fastq")
        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(canonicalPath(manifestURL)))
        XCTAssertTrue(
            outputPaths.contains(canonicalPath(copiedChunkURL)),
            "Missing output \(canonicalPath(copiedChunkURL)); outputs:\n\(outputPaths.sorted().joined(separator: "\n"))"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputURL
                .appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.provenanceFilename)
                .path
        ))
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

    private func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        let data = try Data(contentsOf: url)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
