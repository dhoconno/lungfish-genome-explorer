// ManifestRowFixturePinTests.swift - The row a registry holds for a folder it did not install
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.24 B66-DELETE, QA 1. Thirty-five test lines adopted a database folder with a registry
// method that no shipped code called. The fixtures now write the row through the manifest with
// `seedRowThroughManifest` (LungfishTestSupport). This suite passes at the base, where the old method still
// exists, so the first test compares the manifest each of the two ways writes, field by field, except the
// dates and the bookmark. The other tests state the row's own facts, so they outlive the old method.

import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

final class ManifestRowFixturePinTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "manifest-row-fixture")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        try await super.tearDown()
    }

    /// A folder of the three Kraken2 files, 10, 20 and 30 bytes long.
    private func makeFolder(named name: String, under parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, size) in [("hash.k2d", 10), ("opts.k2d", 20), ("taxo.k2d", 30)] {
            try Data(repeating: 0x41, count: size).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    /// The manifest under `base` with the dates and the bookmark of every row taken out.
    private func manifestWithoutDates(in base: URL) throws -> NSDictionary {
        let data = try Data(contentsOf: base.appendingPathComponent("metagenomics-db-registry.json"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(manifest["databases"] as? [[String: Any]])
        manifest["databases"] = rows.map { row -> [String: Any] in
            var kept = row
            for key in ["installedAt", "lastUpdated", "bookmarkData"] { kept.removeValue(forKey: key) }
            return kept
        }
        return manifest as NSDictionary
    }

    func testTheSeededManifestHoldsTheFieldsTheOldMethodWrote() async throws {
        let cases = [("my-viral-db", "Lab Index"), ("plain-db", "Plain DB"), ("viral", "Viral")]
        for (index, (folderName, rowName)) in cases.enumerated() {
            let parent = scratch.appendingPathComponent("case-\(index)", isDirectory: true)
            let folder = try makeFolder(named: folderName, under: parent)
            let baseOfOldMethod = parent.appendingPathComponent("old-method", isDirectory: true)
            let baseOfHelper = parent.appendingPathComponent("helper", isDirectory: true)

            let adopted = MetagenomicsDatabaseRegistry(baseDirectory: baseOfOldMethod)
            try await adopted.registerExisting(at: folder, name: rowName)
            let seeded = MetagenomicsDatabaseRegistry(baseDirectory: baseOfHelper)
            let row = try await seeded.seedRowThroughManifest(at: folder, name: rowName)

            XCTAssertEqual(row.name, rowName)
            XCTAssertEqual(row.path?.path, folder.path, "case \(rowName) holds the folder")
            XCTAssertEqual(
                try manifestWithoutDates(in: baseOfHelper), try manifestWithoutDates(in: baseOfOldMethod),
                "case \(rowName) writes the manifest the old method wrote"
            )
        }
    }

    /// BIO 4. A folder adopted under a catalog display name has no install receipt, so nothing checked its
    /// files against the catalog's build. The row keeps the catalog identity, which an update still needs,
    /// and records no version and no receipt digest. The row is offered the catalog build, and a load does
    /// not give it the catalog's label.
    func testARowUnderACatalogNameKeepsItsIdentityAndRecordsNoVersion() async throws {
        let folder = try makeFolder(named: "viral-no-receipt", under: scratch)
        let base = scratch.appendingPathComponent("catalog-name", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)

        let row = try await registry.seedRowThroughManifest(at: folder, name: "Viral")

        XCTAssertEqual(row.catalogID, "kraken2-viral", "the row keeps the catalog identity")
        XCTAssertNil(row.version, "the files were never checked, so the row must not repeat the catalog's label")
        XCTAssertNil(row.canonicalReceiptSHA256, "no receipt was read, so no digest is recorded")
        XCTAssertNil(row.payloadDigest)
        XCTAssertEqual(row.status, .ready)
        XCTAssertEqual(row.path?.path, folder.path)
        XCTAssertFalse(row.isExternal)
        XCTAssertNil(row.bookmarkData)
        XCTAssertNotNil(row.installedAt)
        XCTAssertNotNil(row.lastUpdated)

        // An update writes the catalog label, so a row with no version is offered it.
        let pinned = try XCTUnwrap(MetagenomicsDatabaseInfo.catalogEntry(catalogID: "kraken2-viral")?.version)
        XCTAssertEqual(row.availableUpdateVersion, pinned, "an unchecked row is offered the catalog build")

        // Nothing at load writes the label back.
        let again = MetagenomicsDatabaseRegistry(baseDirectory: base)
        let loaded = try await again.database(named: "Viral")
        XCTAssertNil(loaded?.version, "a load does not give the row the catalog's label")
        XCTAssertEqual(loaded?.catalogID, "kraken2-viral")
    }

    func testARowUnderAnUnknownNameIsAUserImportedKraken2DatabaseSizedFromItsFiles() async throws {
        let folder = try makeFolder(named: "my-viral-db", under: scratch)
        let base = scratch.appendingPathComponent("unknown-name", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)

        let row = try await registry.seedRowThroughManifest(at: folder, name: "Lab Index")

        XCTAssertEqual(row.name, "Lab Index")
        XCTAssertEqual(row.tool, "kraken2")
        XCTAssertNil(row.version)
        XCTAssertNil(row.catalogID)
        XCTAssertNil(row.downloadURL)
        XCTAssertEqual(row.description, "User-imported Kraken2 database")
        XCTAssertEqual(row.collection, .viral, "the folder name picks the collection")
        XCTAssertEqual(row.sizeBytes, 60)
        XCTAssertEqual(row.sizeOnDisk, 60)
        XCTAssertEqual(row.recommendedRAM, 60)
        XCTAssertEqual(row.status, .ready)
        XCTAssertTrue(row.isDownloaded)
        XCTAssertEqual(row.path?.path, folder.path)
        XCTAssertNotNil(row.installedAt)
        XCTAssertNotNil(row.lastUpdated)

        let again = MetagenomicsDatabaseRegistry(baseDirectory: base)
        let loaded = try await again.database(named: "Lab Index")
        XCTAssertEqual(loaded?.path?.path, folder.path, "another registry reads the row from the manifest")
        XCTAssertEqual(loaded?.status, .ready)
    }

    func testARowCarriesTheExternalFlagAndTheBookmarkItIsGiven() async throws {
        let folder = try makeFolder(named: "external-db", under: scratch)
        let base = scratch.appendingPathComponent("external", isDirectory: true)
        let bookmark = Data([0x4c, 0x46, 0x45])
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)

        let row = try await registry.seedRowThroughManifest(
            at: folder, name: "External DB", isExternal: true, bookmarkData: bookmark
        )

        XCTAssertTrue(row.isExternal)
        XCTAssertEqual(row.bookmarkData, bookmark)
        let again = MetagenomicsDatabaseRegistry(baseDirectory: base)
        let loaded = try await again.database(named: "External DB")
        XCTAssertEqual(loaded?.bookmarkData, bookmark, "the manifest holds the bookmark")
    }
}
