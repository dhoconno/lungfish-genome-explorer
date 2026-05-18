import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ONTImportOperationCoordinatorTests: XCTestCase {
    func testCoordinatorRunsWorkflowWithGUIContextAndCompletesOperationCenter() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("fastq_pass", isDirectory: true)
        let outputURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try writeONTChunk(under: sourceURL, barcode: "barcode01", filename: "chunk_0.fastq")

        let center = OperationCenter()
        let coordinator = ONTImportOperationCoordinator(operationCenter: center)
        let result = try await coordinator.importDirectory(
            sourceURL: sourceURL,
            projectURL: outputURL,
            includeUnclassified: true,
            concurrency: 1,
            routeContext: OperationRouteContext(projectURL: outputURL, windowStateScopeID: nil)
        )

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.bundleURLs, result.importResult.bundleURLs)
        XCTAssertEqual(item.cliCommand, OperationCenter.buildCLICommand(
            subcommand: "fastq import-ont",
            args: [
                sourceURL.path,
                "--output", outputURL.path,
                "--include-unclassified",
                "--concurrency", "1"
            ]
        ))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"]?.stringValue, "gui")
        XCTAssertEqual(envelope.options.resolvedDefaults["includeUnclassified"]?.booleanValue, true)
        XCTAssertEqual(envelope.options.resolvedDefaults["concurrency"]?.integerValue, 1)
        XCTAssertEqual(envelope.argv.first, "lungfish")
        XCTAssertTrue(envelope.reproducibleCommand.contains("fastq import-ont"))
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
            .appendingPathComponent("ONTImportOperationCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
