// DatabaseRegistryTests.swift - Tests for bundled manifest and managed database resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishCore

final class DatabaseRegistryTests: XCTestCase {

    private var tempDir: URL!
    private let overrideKey = "database.human-scrubber.overrideFilename"

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-database-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: overrideKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: overrideKey)
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testHumanScrubberManifestLoadsFromBundledMetadataWithoutPayload() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try makeBundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("user-databases")
        )

        let manifest = await registry.manifest(for: "human-scrubber")

        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.id, "human-scrubber")
        XCTAssertEqual(manifest?.displayName, "Human Read Scrubber Database")
        XCTAssertEqual(manifest?.filename, "human_filter.db.20250916v2")
        XCTAssertEqual(manifest?.releaseDate, "2025-09-16")
        XCTAssertEqual(
            manifest?.description,
            "k-mer database for human read identification and removal, built from human RefSeq. Eukaryota-derived k-mers with non-Eukaryota k-mers subtracted. Conservative on viral and bacterial pathogens."
        )
    }

    func testEffectiveDatabasePathPrefersInstalledHumanScrubberCopy() async throws {
        let bundledRoot = try makeBundledDatabasesRoot()
        let bundledPayload = try makeBundledHumanScrubberPayload(
            at: bundledRoot,
            filename: "human_filter.db.20250916v2",
            contents: Data(repeating: 0x11, count: 16)
        )
        let userRoot = tempDir.appendingPathComponent("user-databases")
        let installed = try makeInstalledHumanScrubber(
            at: userRoot,
            filename: "human_filter.db.user-installed",
            contents: Data(repeating: 0x7F, count: 32)
        )
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            userDatabasesRoot: userRoot
        )

        let resolved = await registry.effectiveDatabasePath(for: "human-scrubber")

        XCTAssertEqual(resolved?.standardizedFileURL.path, installed.standardizedFileURL.path)
        XCTAssertNotEqual(resolved?.standardizedFileURL.path, bundledPayload.standardizedFileURL.path)
    }

    func testEffectiveDatabasePathReturnsNilWhenHumanScrubberNotInstalled() async throws {
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try makeBundledDatabasesRoot(),
            userDatabasesRoot: tempDir.appendingPathComponent("user-databases")
        )

        let resolved = await registry.effectiveDatabasePath(for: "human-scrubber")

        XCTAssertNil(resolved)
    }

    func testEffectiveDatabasePathIgnoresPartialManagedDatabaseArtifacts() async throws {
        let userRoot = tempDir.appendingPathComponent("user-databases")
        let dir = userRoot.appendingPathComponent("deacon-panhuman")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("panhuman-1.k31w15.idx.tmp").path,
            contents: Data(repeating: 0x22, count: 32)
        )

        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try makeBundledDatabasesRoot(),
            userDatabasesRoot: userRoot
        )

        let resolved = await registry.effectiveDatabasePath(for: "deacon-panhuman")

        XCTAssertNil(resolved)
    }

    func testEffectiveDatabasePathUsesConfiguredManagedStorageRoot() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let configuredRoot = home.appendingPathComponent("shared-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let bundledRoot = try makeBundledDatabasesRoot()
        let installed = try makeInstalledHumanScrubber(
            at: configuredRoot.appendingPathComponent("databases", isDirectory: true),
            filename: "human_filter.db.custom-root",
            contents: Data(repeating: 0x55, count: 32)
        )
        let registry = DatabaseRegistry(
            bundledDatabasesRoot: bundledRoot,
            storageConfigStore: store
        )

        let resolved = await registry.effectiveDatabasePath(for: "human-scrubber")

        XCTAssertEqual(resolved?.standardizedFileURL.path, installed.standardizedFileURL.path)
    }

    /// Root for bundled-payload lookups only. Manifest metadata (filename, version,
    /// description, etc.) now comes from `ManagedToolLock.bundled` regardless of this
    /// directory's contents, so this just needs to exist for `databasesRoot()`.
    private func makeBundledDatabasesRoot() throws -> URL {
        let root = tempDir.appendingPathComponent("bundled-databases")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("human-scrubber"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("deacon-panhuman"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func makeBundledHumanScrubberPayload(at bundledRoot: URL, filename: String, contents: Data) throws -> URL {
        let dir = bundledRoot.appendingPathComponent("human-scrubber")
        let fileURL = dir.appendingPathComponent(filename)
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: contents
        )
        return fileURL
    }

    private func makeInstalledHumanScrubber(at userRoot: URL, filename: String, contents: Data) throws -> URL {
        let dir = userRoot.appendingPathComponent("human-scrubber")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent(filename)
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: contents
        )
        return fileURL
    }
}
