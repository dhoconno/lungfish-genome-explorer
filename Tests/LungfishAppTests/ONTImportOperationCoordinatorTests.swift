import Foundation
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
import XCTest

@MainActor
final class ONTImportOperationCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-import-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testCoordinatorRunsWorkflowAndCompletesOperationCenter() async throws {
        let sourceURL = try makeONTSource()
        let projectURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        let center = OperationCenter()
        let coordinator = ONTImportOperationCoordinator(operationCenter: center)

        let result = try await coordinator.importDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: true,
            concurrency: 1,
            routeContext: routeContext
        )

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.bundleURLs, result.importResult.bundleURLs)
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(item.cliCommand, OperationCenter.buildCLICommand(
            subcommand: "fastq import-ont",
            args: [
                sourceURL.path,
                "--output", projectURL.path,
                "--include-unclassified",
                "--concurrency", "1",
            ]
        ))

        let envelope = try readEnvelope(projectURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("gui"))
        XCTAssertEqual(envelope.options.resolvedDefaults["includeUnclassified"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["concurrency"], .integer(1))
        XCTAssertEqual(envelope.argv.first, "lungfish")
        XCTAssertTrue(envelope.reproducibleCommand.contains("fastq import-ont"))
    }

    private func makeONTSource() throws -> URL {
        let sourceURL = tempDir.appendingPathComponent("fastq_pass", isDirectory: true)
        let barcodeURL = sourceURL.appendingPathComponent("barcode01", isDirectory: true)
        let unclassifiedURL = sourceURL.appendingPathComponent("unclassified", isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unclassifiedURL, withIntermediateDirectories: true)
        let text = """
        @read1 runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01 basecall_model_version_id=dorado-test
        ACGT
        +
        !!!!

        """
        try text.write(to: barcodeURL.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        try text.write(to: unclassifiedURL.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        return sourceURL
    }

    private func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        let data = try Data(contentsOf: url)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
    }
}
