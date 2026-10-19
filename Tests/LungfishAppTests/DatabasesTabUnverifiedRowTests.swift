// DatabasesTabUnverifiedRowTests.swift — a database row adopted from a folder under a catalog name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.26, B5 (UX ruling U-W5 and U-W7, BIO's line). A ready row that records the catalog identity of
/// `Standard-8` and neither digest is a folder an older build adopted (its version label is the catalog's) or a build
/// that adopts one now (`registerExisting` records no version). The tab, the update gate and the reconciler read it.
@MainActor
final class DatabasesTabUnverifiedRowTests: XCTestCase {

    private static let catalogID = "kraken2-standard-8"

    private func catalogVersion() throws -> String {
        try XCTUnwrap(ManagedToolLock.bundled.database(id: Self.catalogID)?.version)
    }

    /// A ready `Standard-8` row with the catalog identity, `version` and neither digest.
    private func adoptedRow(version: String?) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: "Standard-8", tool: MetagenomicsTool.kraken2.rawValue, version: version, sizeBytes: 1024,
            catalogID: Self.catalogID, description: "Adopted from a folder", collection: .standard8,
            path: URL(fileURLWithPath: "/tmp/standard-8"), status: .ready, recommendedRAM: 1024
        )
    }

    // MARK: - As the rows read at the base (M1 pins)

    /// An older build's adoption keeps the catalog's version, so the row reads as current: it shows that version,
    /// offers no Update and the reconciler keys it by that version.
    func testARowAdoptedWithTheCatalogVersionReadsAsCurrentAtTheBase() throws {
        let version = try catalogVersion()
        let row = adoptedRow(version: version)
        XCTAssertNil(row.canonicalReceiptSHA256)
        XCTAssertNil(row.payloadDigest)
        XCTAssertTrue(PluginManagerViewModel.databaseTrackingSummary(for: row).contains("Version \(version)"))
        XCTAssertFalse(PluginManagerViewModel(automaticallyRefresh: false).canUpdateDatabase(row))
        XCTAssertEqual(ReconcilerServices.metagenomicsDatabaseVersions(from: [row]), [Self.catalogID: version])
    }

    /// A build that adopts the folder now records no version. The tab offers the catalog build as an update and the
    /// reconciler has no key for the row.
    func testARowAdoptedWithNoVersionOffersTheUpdateAndHasNoReconcilerKeyAtTheBase() throws {
        let row = adoptedRow(version: nil)
        XCTAssertTrue(PluginManagerViewModel.databaseTrackingSummary(for: row).contains("Version unknown"))
        XCTAssertTrue(PluginManagerViewModel(automaticallyRefresh: false).canUpdateDatabase(row))
        XCTAssertEqual(ReconcilerServices.metagenomicsDatabaseVersions(from: [row]), [:])
    }
}
