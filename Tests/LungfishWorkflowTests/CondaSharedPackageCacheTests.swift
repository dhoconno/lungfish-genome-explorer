// CondaSharedPackageCacheTests.swift - .mambarc shared pkgs_dirs configuration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishCore

final class CondaSharedPackageCacheTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("conda-shared-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        try await super.tearDown()
    }

    private func cache(environment: [String: String] = [:], sameVolume: Bool = true) -> CondaSharedPackageCache {
        CondaSharedPackageCache(homeDirectory: home, environment: environment, sameVolume: { _, _ in sameVolume })
    }

    func testConfigureWritesSharedCacheFirstAndOwnCacheSecond() throws {
        let root = home.appendingPathComponent(".lungfish/conda", isDirectory: true)
        let shared = try XCTUnwrap(cache().configure(rootPrefix: root))

        XCTAssertEqual(shared, home.standardizedFileURL.appendingPathComponent(".lungfish-shared/conda/pkgs", isDirectory: true))
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let contents = try String(contentsOf: root.appendingPathComponent(".mambarc"), encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix(CondaSharedPackageCache.marker))
        let lines = contents.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let pkgsIndex = try XCTUnwrap(lines.firstIndex(of: "pkgs_dirs:"))
        XCTAssertEqual(lines[pkgsIndex + 1], "- \(shared.path)")
        XCTAssertEqual(lines[pkgsIndex + 2], "- \(root.standardizedFileURL.appendingPathComponent("pkgs", isDirectory: true).path)")

        // Idempotent: a second configure leaves the file untouched.
        let before = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".mambarc").path)[.modificationDate] as? Date
        XCTAssertNotNil(try cache().configure(rootPrefix: root))
        let after = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".mambarc").path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testDifferentVolumeKeepsPerRootCacheAndRemovesManagedFile() throws {
        let root = home.appendingPathComponent(".lungfish-stable/conda", isDirectory: true)
        XCTAssertNotNil(try cache().configure(rootPrefix: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mambarc").path))

        XCTAssertNil(try cache(sameVolume: false).configure(rootPrefix: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mambarc").path))
    }

    func testEnvironmentDisablesOrRelocatesSharing() throws {
        let root = home.appendingPathComponent(".lungfish/conda", isDirectory: true)
        XCTAssertNil(cache(environment: [CondaSharedPackageCache.environmentKey: "0"]).sharedCacheURL)
        XCTAssertNil(try cache(environment: [CondaSharedPackageCache.environmentKey: "off"]).configure(rootPrefix: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mambarc").path))

        let custom = home.appendingPathComponent("elsewhere/pkgs", isDirectory: true)
        let shared = try cache(environment: [CondaSharedPackageCache.environmentKey: custom.path]).configure(rootPrefix: root)
        XCTAssertEqual(shared, custom.standardizedFileURL)
    }

    func testUserAuthoredConfigurationIsLeftAlone() throws {
        let root = home.appendingPathComponent(".lungfish/conda", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(".mambarc")
        try "channels:\n  - conda-forge\n".write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertNil(try cache().configure(rootPrefix: root))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "channels:\n  - conda-forge\n")
        XCTAssertNil(try cache(sameVolume: false).configure(rootPrefix: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }
}
