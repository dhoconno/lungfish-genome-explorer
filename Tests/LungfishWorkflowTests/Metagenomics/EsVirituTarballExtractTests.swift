// EsVirituTarballExtractTests.swift - EsViritu's tar extract on ToolProcess and its path-escape rule
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class EsVirituTarballExtractTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try DemoProjectFixtures.makeTempDirectory("esviritu-tar")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeManager() -> EsVirituDatabaseManager {
        EsVirituDatabaseManager(storageRoot: tempDir.appendingPathComponent("storage", isDirectory: true))
    }

    private func makeDestination() throws -> URL {
        let destination = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    func testExtractsAndStripsTheTopFolder() async throws {
        let archive = tempDir.appendingPathComponent("db.tar.gz")
        try TestTarWriter.write([.directory("db-1.0"), .file("db-1.0/hash.dmnd", "d")], to: archive)
        let destination = try makeDestination()
        try await makeManager().extractTarball(at: archive, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("hash.dmnd"), encoding: .utf8), "d")
    }

    func testCarriesTarsStderrWhenTarRefusesAnEntry() async throws {
        let archive = tempDir.appendingPathComponent("db-dotdot.tar.gz")
        // --strip-components=1 removes the first name component, so a bare `../x` would lose its `..`.
        let escape = "escape-\(UUID().uuidString).txt"
        try TestTarWriter.write([.file("db/ok.txt", "ok"), .file("db/../../\(escape)", "pwned")], to: archive)
        defer { XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(escape).path)) }
        let destination = try makeDestination()
        do {
            try await makeManager().extractTarball(at: archive, to: destination)
            XCTFail("expected a failure")
        } catch EsVirituDatabaseError.extractionFailed(let message) {
            XCTAssertTrue(message.contains("Path contains '..'"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a failed extract left its folder")
    }

    func testRefusesASymbolicLinkThatLeavesTheFolder() async throws {
        let archive = tempDir.appendingPathComponent("db-link.tar.gz")
        try TestTarWriter.write([.file("db/ok.txt", "ok"), .symlink("db/link", to: "../../outside")], to: archive)
        let destination = try makeDestination()
        do {
            try await makeManager().extractTarball(at: archive, to: destination)
            XCTFail("the archive was accepted")
        } catch EsVirituDatabaseError.extractionFailed(let message) {
            XCTAssertTrue(message.contains("refused because it is unsafe"), message)
            XCTAssertTrue(message.contains("points outside"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a refused extract left its folder")
    }

    func testACancelledExtractThrowsCancellationAndRemovesTheFolder() async throws {
        let archive = tempDir.appendingPathComponent("db-cancel.tar.gz")
        try TestTarWriter.write([.directory("db-1.0"), .file("db-1.0/hash.dmnd", "d")], to: archive)
        let destination = try makeDestination()
        let manager = makeManager()
        // The task spins until it is cancelled, so the extract starts already cancelled and nothing launches.
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await manager.extractTarball(at: archive, to: destination)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("the extract was not cancelled")
        } catch is CancellationError {
            // Cancelled.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a cancelled extract left its folder")
    }
}
