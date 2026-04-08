// Tests/LungfishAppTests/ClassifierDatabaseRoutingTests.swift
import XCTest
@testable import LungfishApp

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
}
