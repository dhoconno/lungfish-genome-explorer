// MetagenomicsDatabaseRegistryReloadTests.swift - The registry reads a manifest another process changed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3 (family L10, plan decision C10). The Plugin Manager's database update runs
// `lungfish-cli conda db update`, which saves the registry manifest in another process. The app's
// registry loads its manifest once, so after the command it reloads from disk to show the
// database the command installed.

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

final class MetagenomicsDatabaseRegistryReloadTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        try await super.setUp()
        base = try TestTempDirectory.make(prefix: "registry-reload")
    }

    override func tearDown() async throws {
        if let base { TestTempDirectory.cleanup(base) }
        try await super.tearDown()
    }

    private func makeDatabase(named name: String) throws -> URL {
        let folder = base.appendingPathComponent("kraken2/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "payload".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return folder
    }

    func testReloadingShowsADatabaseAnotherRegistrySavedAndPlainLoadingDoesNot() async throws {
        let app = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await app.loadIfNeeded()
        let absent = try await app.database(named: "Lab Index")
        XCTAssertNil(absent)

        // The CLI process saves a row in the same manifest.
        let cli = MetagenomicsDatabaseRegistry(baseDirectory: base)
        _ = try await cli.seedRowThroughManifest(at: try makeDatabase(named: "lab-index"), name: "Lab Index")

        try await app.loadIfNeeded()
        let stale = try await app.database(named: "Lab Index")
        XCTAssertNil(stale, "a loaded registry keeps the rows it holds")

        try await app.reloadFromDisk()
        let row = try await app.database(named: "Lab Index")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.status, .ready)
    }
}
