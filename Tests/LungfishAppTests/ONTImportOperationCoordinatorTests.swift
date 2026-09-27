import Foundation
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
import XCTest
import LungfishKit

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

        let expectedOutputURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(tempDir.lastPathComponent, isDirectory: true)
        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.bundleURLs, result.importResult.bundleURLs)
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertEqual(item.cliCommand, OperationCenter.buildCLICommand(
            subcommand: "fastq import-ont",
            args: [
                sourceURL.path,
                "--output", expectedOutputURL.path,
                "--include-unclassified",
                "--concurrency", "1",
            ]
        ))
        let bundleURL = try XCTUnwrap(result.importResult.bundleURLs.first)
        XCTAssertEqual(
            bundleURL.deletingLastPathComponent().standardizedFileURL,
            expectedOutputURL.standardizedFileURL,
            "ONT bundles belong under Imports/<run name>/ like every other import"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true).path
        ))

        let envelope = try readEnvelope(expectedOutputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("gui"))
        XCTAssertEqual(envelope.options.resolvedDefaults["includeUnclassified"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["concurrency"], .integer(1))
        XCTAssertEqual(envelope.argv.first, "lungfish-cli")
        XCTAssertTrue(envelope.reproducibleCommand.contains("fastq import-ont"))
    }

    func testCoordinatorUsesUniqueOutputDirectoryWhenImportsRunFolderHasPreviousONTOutputs() async throws {
        let runURL = tempDir.appendingPathComponent("Run42", isDirectory: true)
        let sourceURL = try makeONTSource(in: runURL)
        let projectURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let previousRunOutput = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("Run42", isDirectory: true)
        try FileManager.default.createDirectory(at: previousRunOutput, withIntermediateDirectories: true)
        try "{}".write(
            to: previousRunOutput.appendingPathComponent(DemultiplexManifest.filename),
            atomically: true,
            encoding: .utf8
        )
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        let center = OperationCenter()
        let coordinator = ONTImportOperationCoordinator(operationCenter: center)

        let result = try await coordinator.importDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: false,
            concurrency: 1,
            routeContext: routeContext
        )

        let expectedOutputURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("Run42 2", isDirectory: true)
        let bundleURL = try XCTUnwrap(result.importResult.bundleURLs.first)
        XCTAssertEqual(bundleURL.deletingLastPathComponent().standardizedFileURL, expectedOutputURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: expectedOutputURL.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true).path
        ))
        // The path holds a space, so the CLI command carries it shell-escaped;
        // check the pieces rather than the raw path.
        let cliCommand = try XCTUnwrap(center.items.first?.cliCommand)
        XCTAssertTrue(cliCommand.contains("--output"))
        XCTAssertTrue(cliCommand.contains("Run42"))
        XCTAssertTrue(cliCommand.contains("'\(expectedOutputURL.path)'"), cliCommand)
    }

    func testResolvedOutputDirectoryAlwaysTargetsImportsRunFolder() throws {
        let runURL = tempDir.appendingPathComponent("My Run.2026", isDirectory: true)
        let sourceURL = try makeONTSource(in: runURL)
        let projectURL = tempDir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let resolved = try ONTImportOperationCoordinator.resolvedOutputDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: false
        )

        XCTAssertEqual(
            resolved.standardizedFileURL,
            projectURL
                .appendingPathComponent("Imports", isDirectory: true)
                .appendingPathComponent("My Run.2026", isDirectory: true)
                .standardizedFileURL
        )

        // Selecting a single barcode folder still names the run after the
        // folder around fastq_pass.
        let barcodeOnly = try ONTImportOperationCoordinator.resolvedOutputDirectory(
            sourceURL: sourceURL.appendingPathComponent("barcode01", isDirectory: true),
            projectURL: projectURL,
            includeUnclassified: false
        )
        XCTAssertEqual(barcodeOnly.lastPathComponent, "My Run.2026")
        XCTAssertEqual(barcodeOnly.deletingLastPathComponent().lastPathComponent, "Imports")
    }

    func testResolvedOutputDirectoryReusesEmptyImportsRunFolderButNotOneHoldingBundles() throws {
        let runURL = tempDir.appendingPathComponent("Run7", isDirectory: true)
        let sourceURL = try makeONTSource(in: runURL)
        let projectURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let runOutput = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("Run7", isDirectory: true)
        try FileManager.default.createDirectory(at: runOutput, withIntermediateDirectories: true)

        let emptyFolder = try ONTImportOperationCoordinator.resolvedOutputDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: false
        )
        XCTAssertEqual(emptyFolder.standardizedFileURL, runOutput.standardizedFileURL)

        try FileManager.default.createDirectory(
            at: runOutput.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true),
            withIntermediateDirectories: true
        )
        let occupied = try ONTImportOperationCoordinator.resolvedOutputDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: false
        )
        XCTAssertEqual(occupied.lastPathComponent, "Run7 2")
    }

    func testLegacyRootLevelONTBundlesAreLeftAloneByNewImports() async throws {
        // Projects from earlier releases hold ONT bundles at the project root.
        // A new import of the same run must not touch them and must land
        // under Imports/ regardless.
        let runURL = tempDir.appendingPathComponent("Run42", isDirectory: true)
        let sourceURL = try makeONTSource(in: runURL)
        let projectURL = tempDir.appendingPathComponent("project", isDirectory: true)
        let legacyBundle = projectURL.appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyBundle, withIntermediateDirectories: true)
        let legacyMarker = legacyBundle.appendingPathComponent("legacy.txt")
        try "keep".write(to: legacyMarker, atomically: true, encoding: .utf8)
        try "{}".write(
            to: projectURL.appendingPathComponent(DemultiplexManifest.filename),
            atomically: true,
            encoding: .utf8
        )
        let center = OperationCenter()
        let coordinator = ONTImportOperationCoordinator(operationCenter: center)

        let result = try await coordinator.importDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: false,
            concurrency: 1,
            routeContext: OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        )

        let bundleURL = try XCTUnwrap(result.importResult.bundleURLs.first)
        XCTAssertEqual(
            bundleURL.deletingLastPathComponent().standardizedFileURL,
            projectURL
                .appendingPathComponent("Imports", isDirectory: true)
                .appendingPathComponent("Run42", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(try String(contentsOf: legacyMarker, encoding: .utf8), "keep")
    }

    func testCoordinatorIncludesFlattenedStorageModeInCLIAndProvenance() async throws {
        let sourceURL = try makeONTSource()
        let projectURL = tempDir.appendingPathComponent("flattened-project", isDirectory: true)
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        let center = OperationCenter()
        let coordinator = ONTImportOperationCoordinator(operationCenter: center)

        let result = try await coordinator.importDirectory(
            sourceURL: sourceURL,
            projectURL: projectURL,
            includeUnclassified: false,
            concurrency: 1,
            storageMode: .flattened,
            routeContext: routeContext
        )

        let item = try XCTUnwrap(center.items.first)
        XCTAssertTrue(item.cliCommand?.contains("--storage-mode flattened") == true)
        let bundleURL = try XCTUnwrap(result.importResult.bundleURLs.first)
        let payloadURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: payloadURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("source-files.json").path
        ))

        let envelope = try readEnvelope(
            bundleURL.deletingLastPathComponent().appendingPathComponent(ProvenanceWriter.provenanceFilename)
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["storageMode"], .string("flattened"))
        XCTAssertEqual(envelope.options.resolvedDefaults["useVirtualConcatenation"], .boolean(false))
    }

    private func makeONTSource() throws -> URL {
        try makeONTSource(in: tempDir)
    }

    private func makeONTSource(in parentURL: URL) throws -> URL {
        let sourceURL = parentURL.appendingPathComponent("fastq_pass", isDirectory: true)
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
