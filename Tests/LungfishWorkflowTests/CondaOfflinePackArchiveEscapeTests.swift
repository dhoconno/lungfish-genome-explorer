// CondaOfflinePackArchiveEscapeTests.swift - The offline pack extract refuses a symbolic link that leaves the folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class CondaOfflinePackArchiveEscapeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try DemoProjectFixtures.makeTempDirectory("conda-pack-tar")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeDestination() throws -> URL {
        let destination = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    func testExtractsAValidPackArchive() throws {
        let archive = tempDir.appendingPathComponent("pack.tgz")
        try TestTarWriter.write([.directory("pack"), .file("pack/manifest.json", "{}")], to: archive)
        let destination = try makeDestination()
        try CondaOfflinePackService.extractArchive(archive, to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("pack/manifest.json"), encoding: .utf8), "{}")
    }

    func testRefusesASymbolicLinkThatLeavesTheFolder() throws {
        let archive = tempDir.appendingPathComponent("pack-link.tgz")
        try TestTarWriter.write([.file("pack/manifest.json", "{}"), .symlink("pack/link", to: "../../outside")], to: archive)
        XCTAssertThrowsError(try CondaOfflinePackService.extractArchive(archive, to: try makeDestination())) { error in
            guard case CondaOfflinePackError.archiveFailed(let operation, let stderr) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(operation, "extract")
            XCTAssertTrue(stderr.contains("refused because it is unsafe"), stderr)
            XCTAssertTrue(stderr.contains("points outside"), stderr)
        }
    }
}
