// MetagenomicsDatabaseRegistryTarballTests.swift - The registry's tar extract on ToolProcess and its path-escape rule
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class MetagenomicsDatabaseRegistryTarballTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try DemoProjectFixtures.makeTempDirectory("registry-tar")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeRegistry() -> MetagenomicsDatabaseRegistry {
        MetagenomicsDatabaseRegistry(baseDirectory: tempDir.appendingPathComponent("registry", isDirectory: true))
    }

    private func makeDestination() throws -> URL {
        let destination = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    func testExtractsAKraken2StyleTarballWithItsFilesAtTheTopLevel() async throws {
        let archive = tempDir.appendingPathComponent("k2.tar.gz")
        try TestTarWriter.write([.file("hash.k2d", "h"), .file("opts.k2d", "o")], to: archive)
        let destination = try makeDestination()
        try await makeRegistry().extractTarball(archive, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("hash.k2d"), encoding: .utf8), "h")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("opts.k2d"), encoding: .utf8), "o")
    }

    func testNamesTheArchiveAndTarsOwnWordsWhenTarRefusesAnEntry() async throws {
        let escape = "escape-\(UUID().uuidString).txt"
        let archive = tempDir.appendingPathComponent("k2-dotdot.tar.gz")
        try TestTarWriter.write([.file("ok.txt", "ok"), .file("../\(escape)", "pwned")], to: archive)
        do {
            try await makeRegistry().extractTarball(archive, to: try makeDestination())
            XCTFail("expected a failure")
        } catch MetagenomicsDatabaseRegistryError.downloadFailed(let name, let reason) {
            XCTAssertEqual(name, "k2-dotdot.tar.gz")
            XCTAssertTrue(reason.hasPrefix("tar extraction failed: "), reason)
            XCTAssertTrue(reason.contains("Path contains '..'"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(escape).path))
    }

    func testRefusesASymbolicLinkThatLeavesTheFolder() async throws {
        let archive = tempDir.appendingPathComponent("k2-link.tar.gz")
        try TestTarWriter.write([.file("ok.txt", "ok"), .symlink("link", to: "../outside")], to: archive)
        do {
            try await makeRegistry().extractTarball(archive, to: try makeDestination())
            XCTFail("the archive was accepted")
        } catch MetagenomicsDatabaseRegistryError.downloadFailed(let name, let reason) {
            XCTAssertEqual(name, "k2-link.tar.gz")
            XCTAssertTrue(reason.contains("refused because it is unsafe"), reason)
            XCTAssertTrue(reason.contains("points outside"), reason)
        }
    }
}
