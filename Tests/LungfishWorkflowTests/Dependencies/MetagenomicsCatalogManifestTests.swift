// MetagenomicsCatalogManifestTests.swift - The metagenomics catalog is derived from the dependency manifest
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Verifies that the built-in metagenomics database catalog, the EsViritu manager, and the
/// on-disk registry all take their versions and URLs from `third-party-tools-lock.json`
/// rather than from Swift literals.
final class MetagenomicsCatalogManifestTests: XCTestCase {

    func testUnpinnedCatalogSourcesAreExplicitAndMutableTaxonomyHasNoFixedVersionClaim() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for spec in manifest.databases where spec.url != nil && spec.sha256 == nil && spec.md5 == nil {
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
            XCTAssertNotNil(encoded["sourcePolicy"], "Unpinned source \(spec.id) needs an explicit retrieval contract")
        }
        let taxonomy = try XCTUnwrap(manifest.database(id: "ncbi-taxonomy"))
        XCTAssertEqual(taxonomy.version, "live")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(taxonomy)) as? [String: Any])
        XCTAssertEqual(encoded["sourcePolicy"] as? String, "liveSnapshot")
    }

    func testKrakenCatalogEntriesUseManifestURLs() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let kraken2Collections = MetagenomicsDatabaseInfo.builtInCatalog.filter {
            $0.tool == MetagenomicsTool.kraken2.rawValue && $0.collection != nil
        }
        XCTAssertEqual(kraken2Collections.count, DatabaseCollection.allCases.count)

        for entry in kraken2Collections {
            let catalogID = try XCTUnwrap(entry.catalogID)
            let spec = try XCTUnwrap(manifest.database(id: catalogID), "\(entry.name) missing from manifest")
            XCTAssertEqual(entry.downloadURL, spec.url)
            XCTAssertEqual(entry.version, spec.version)
            XCTAssertEqual(entry.name, spec.displayName)
            XCTAssertEqual(
                entry.installationRecipe,
                .archive(url: try XCTUnwrap(URL(string: try XCTUnwrap(spec.url))))
            )
        }
    }

    func testSpecialAndArchiveCatalogEntriesUseManifestMetadata() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for catalogID in ["kraken2-special-silva", "kraken2-special-greengenes", "esviritu-viral-v3", "ncbi-taxonomy"] {
            let entry = try XCTUnwrap(
                MetagenomicsDatabaseInfo.catalogEntry(catalogID: catalogID),
                "\(catalogID) missing from the built-in catalog"
            )
            let spec = try XCTUnwrap(manifest.database(id: catalogID), "\(catalogID) missing from manifest")
            XCTAssertEqual(entry.name, spec.displayName)
            XCTAssertEqual(entry.version, spec.version)
            XCTAssertEqual(entry.sizeBytes, spec.sizeBytes)
            XCTAssertEqual(entry.sizeOnDisk, spec.sizeOnDisk)
            XCTAssertEqual(entry.recommendedRAM, spec.recommendedRAM)
            XCTAssertEqual(entry.description, spec.description)
            XCTAssertEqual(entry.downloadURL, spec.url)
        }
    }

    func testEuPathDBPointsAtExistingArchive() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.database(id: "kraken2-eupathdb46"))
        let entry = try XCTUnwrap(
            MetagenomicsDatabaseInfo.builtInCatalog.first { $0.catalogID == "kraken2-eupathdb46" }
        )
        XCTAssertEqual(entry.version, spec.version)
        XCTAssertEqual(entry.downloadURL, spec.url)
        // The retired 20240904 EuPathDB archive is a 404 upstream; the pinned build must differ.
        XCTAssertFalse(try XCTUnwrap(entry.downloadURL).contains("20240904"))
    }

    func testEsVirituManagerAgreesWithManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(manifest.database(id: "esviritu-viral-v3"))
        XCTAssertEqual(EsVirituDatabaseManager.currentVersion, spec.version)
        XCTAssertEqual(EsVirituDatabaseManager.downloadURL, spec.url)
    }

    func testRegistryCorrectsDeadCatalogURLOnLoad() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tmp)
        // Seed a stale registry file: EuPathDB with the dead 20240904 URL, status missing.
        let deadURL = "https://genome-idx.s3.amazonaws.com/kraken/k2_eupathdb48_20240904.tar.gz"
        let stale = """
        {"version":1,"databases":[{"name":"EuPathDB46","tool":"kraken2","version":"20240904",\
        "sizeBytes":1,"downloadURL":"\(deadURL)","catalogID":"kraken2-eupathdb46",\
        "installationRecipe":{"archive":{"url":"\(deadURL)"}},"description":"x",\
        "collection":"eupathdb46","isExternal":false,"status":"missing","recommendedRAM":1}]}
        """
        try stale.write(to: tmp.appendingPathComponent("metagenomics-db-registry.json"), atomically: true, encoding: .utf8)

        let spec = try XCTUnwrap(ManagedToolLock.bundled.database(id: "kraken2-eupathdb46"))
        let loaded = try await registry.database(named: "EuPathDB46")
        let db = try XCTUnwrap(loaded)
        XCTAssertEqual(db.version, spec.version)
        XCTAssertEqual(db.downloadURL, spec.url)
        XCTAssertEqual(db.installationRecipe, .archive(url: try XCTUnwrap(URL(string: try XCTUnwrap(spec.url)))))

        // The correction is persisted, so a fresh registry over the same directory sees it too.
        let reloaded = MetagenomicsDatabaseRegistry(baseDirectory: tmp)
        let reloadedEntry = try await reloaded.database(named: "EuPathDB46")
        let persisted = try XCTUnwrap(reloadedEntry)
        XCTAssertEqual(persisted.downloadURL, spec.url)
    }

    func testInstalledDatabasesAreNotRewrittenByReconciliation() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let installedURL = "https://genome-idx.s3.amazonaws.com/kraken/k2_eupathdb48_20240904.tar.gz"
        let installed = """
        {"version":1,"databases":[{"name":"EuPathDB46","tool":"kraken2","version":"20240904",\
        "sizeBytes":1,"downloadURL":"\(installedURL)","catalogID":"kraken2-eupathdb46",\
        "installationRecipe":{"archive":{"url":"\(installedURL)"}},"description":"x",\
        "collection":"eupathdb46","isExternal":false,"status":"ready",\
        "path":"file:///tmp/eupathdb46","recommendedRAM":1}]}
        """
        try installed.write(to: tmp.appendingPathComponent("metagenomics-db-registry.json"), atomically: true, encoding: .utf8)

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: tmp)
        let loaded = try await registry.database(named: "EuPathDB46")
        let db = try XCTUnwrap(loaded)
        XCTAssertEqual(db.version, "20240904", "An installed database keeps the build it was installed from")
        XCTAssertEqual(db.downloadURL, installedURL)
    }
}
