// Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class ClassifierDatabaseRoutingTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - TaxTriage

    func testRoute_taxTriageWithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("taxtriage-2026-04-06T20-46-18")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("taxtriage.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertEqual(route?.displayName, "TaxTriage")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_taxTriageWithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("taxtriage-2026-04-06T20-46-18")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - Kraken2

    func testRoute_kraken2WithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("kraken2-batch-2026-04-06T20-45-49")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_kraken2WithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("kraken2-batch-2026-04-06T20-45-49")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - EsViritu

    func testRoute_esVirituWithDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_esVirituWithoutDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNil(route?.databaseURL)
    }

    // MARK: - Non-classifier directories

    func testRoute_perSampleSubdir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("SRR35517702")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    func testRoute_unrelatedDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("spades-2026-04-06T10-00-00")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }

    func testRoute_classificationPrefix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("classification-batch-2026-04-06")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    // MARK: - Parent walk (batch child subdirs)

    func testRoute_batchChildResolvesToParentBatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let batchDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        let sampleDir = batchDir.appendingPathComponent("SRR35517702")
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: batchDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: sampleDir)
        XCTAssertNotNil(route)
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertEqual(route?.sampleId, "SRR35517702")
        XCTAssertNotNil(route?.databaseURL)
        XCTAssertEqual(route?.databaseURL?.path, batchDir.appendingPathComponent("esviritu.sqlite").path)
        XCTAssertEqual(route?.resultURL.path, batchDir.path)
    }

    func testRoute_topLevelHasNoSampleId() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let batchDir = dir.appendingPathComponent("esviritu-batch-2026-04-06T20-46-01")
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: batchDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: batchDir)
        XCTAssertNotNil(route)
        XCTAssertNil(route?.sampleId, "top-level route should not carry a sampleId")
        XCTAssertEqual(route?.resultURL.path, batchDir.path)
    }

    // MARK: - WFL-06: renamed directories must route via analysis-metadata.json

    func testRoute_renamedTaxTriageDirectoryRoutesByMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A user-chosen name that does not start with any known tool prefix.
        let resultDir = dir.appendingPathComponent("Clinical Batch 7")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("taxtriage.sqlite").path,
            contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true), to: resultDir)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route, "A renamed directory with analysis-metadata.json must still route")
        XCTAssertEqual(route?.tool, "taxtriage")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_renamedEsVirituDirectoryRoutesByMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("Weekly Surveillance")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("esviritu.sqlite").path,
            contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "esviritu", isBatch: true), to: resultDir)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route, "A renamed directory with analysis-metadata.json must still route")
        XCTAssertEqual(route?.tool, "esviritu")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_renamedKraken2DirectoryRoutesByMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resultDir = dir.appendingPathComponent("Project Alpha Results")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: true), to: resultDir)

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNotNil(route, "A renamed directory with analysis-metadata.json must still route")
        XCTAssertEqual(route?.tool, "kraken2")
        XCTAssertNotNil(route?.databaseURL)
    }

    func testRoute_renamedDirectoryWithoutMetadataDoesNotRoute() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No metadata sidecar and no recognizable prefix: legacy behaviour
        // (cannot be identified) must be preserved, not silently misrouted.
        let resultDir = dir.appendingPathComponent("Some Random Folder")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: resultDir.appendingPathComponent("kraken2.sqlite").path,
            contents: Data())

        let route = ClassifierDatabaseRouter.route(for: resultDir)
        XCTAssertNil(route)
    }
}
