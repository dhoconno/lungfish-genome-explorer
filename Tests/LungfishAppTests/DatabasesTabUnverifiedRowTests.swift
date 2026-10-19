// DatabasesTabUnverifiedRowTests.swift — a database row adopted from a folder under a catalog name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.26, B5 (UX ruling U-W5 and U-W7, BIO's line). A ready row that records the catalog identity of
/// `Standard-8` and lacks either digest is a folder an older build adopted (its version label is the catalog's), a
/// build that adopts one now (`registerExisting` records no version) or a download made before receipts existed.
/// Nothing checked its files against a catalog build, so the tab, the update gate, the new classification records and
/// the reconciler read it as unverified. The words below are the ruling's, written out so a change to them shows here.
@MainActor
final class DatabasesTabUnverifiedRowTests: XCTestCase {

    private static let catalogID = "kraken2-standard-8"
    private static let firstSentence = "LGE has not checked these files against a catalog build, so their version is not known."
    private static let helpWords = firstSentence + " Update the database to replace them with a checked copy."

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

    /// The same row once an install receipt bound it to a build: both digests recorded.
    private func boundRow(version: String) -> MetagenomicsDatabaseInfo {
        var row = adoptedRow(version: version)
        row.payloadDigest = "sha256:payload-fixture"
        row.canonicalReceiptSHA256 = "receipt-fixture"
        return row
    }

    // MARK: - M2

    /// An older build's adoption keeps the catalog's version, which nothing checked. The row reads Unverified with the
    /// help words, the catalog build is offered as an update and the reconciler plans the row as drift.
    func testARowAdoptedWithTheCatalogVersionReadsUnverifiedAndOffersTheUpdate() throws {
        let version = try catalogVersion()
        let row = adoptedRow(version: version)
        XCTAssertNil(row.canonicalReceiptSHA256)
        XCTAssertNil(row.payloadDigest)
        let summary = PluginManagerViewModel.databaseTrackingSummary(for: row)
        XCTAssertTrue(summary.contains("Unverified"), summary)
        XCTAssertFalse(summary.contains("Version"), summary)
        XCTAssertTrue(summary.contains("Update available: \(version)"), summary)
        XCTAssertEqual(PluginManagerViewModel.databaseTrackingHelp(for: row), Self.helpWords)
        XCTAssertTrue(PluginManagerViewModel(automaticallyRefresh: false).canUpdateDatabase(row))
        XCTAssertEqual(ReconcilerServices.metagenomicsDatabaseVersions(from: [row]), [Self.catalogID: "unknown"])
        XCTAssertTrue(row.isUnverified)
        XCTAssertNil(row.checkedVersion)
        XCTAssertEqual(row.currentVersionLabel, "Unverified")
        XCTAssertEqual(row.availableUpdateVersion, version)
    }

    /// A build that adopts the folder now records no version. The row reads Unverified like the older adoption.
    func testARowAdoptedWithNoVersionReadsUnverifiedAndOffersTheUpdate() throws {
        let row = adoptedRow(version: nil)
        let summary = PluginManagerViewModel.databaseTrackingSummary(for: row)
        XCTAssertTrue(summary.contains("Unverified"), summary)
        XCTAssertFalse(summary.contains("Version"), summary)
        XCTAssertEqual(PluginManagerViewModel.databaseTrackingHelp(for: row), Self.helpWords)
        XCTAssertTrue(PluginManagerViewModel(automaticallyRefresh: false).canUpdateDatabase(row))
        XCTAssertEqual(ReconcilerServices.metagenomicsDatabaseVersions(from: [row]), [Self.catalogID: "unknown"])
        XCTAssertTrue(row.isUnverified)
        XCTAssertEqual(row.currentVersionLabel, "Unverified")
        XCTAssertEqual(row.availableUpdateVersion, try catalogVersion())
    }

    /// Negative control. A bound row with both digests keeps its version, its label and its check.
    func testABoundRowWithBothDigestsKeepsItsVersionItsLabelAndItsCheck() throws {
        let version = try catalogVersion()
        let row = boundRow(version: version)
        let summary = PluginManagerViewModel.databaseTrackingSummary(for: row)
        XCTAssertTrue(summary.contains("Version \(version)"), summary)
        XCTAssertFalse(summary.contains("Unverified"), summary)
        XCTAssertEqual(PluginManagerViewModel.databaseTrackingHelp(for: row), "")
        XCTAssertFalse(PluginManagerViewModel(automaticallyRefresh: false).canUpdateDatabase(row))
        XCTAssertEqual(ReconcilerServices.metagenomicsDatabaseVersions(from: [row]), [Self.catalogID: version])
        XCTAssertFalse(row.isUnverified)
        XCTAssertEqual(row.checkedVersion, version)
        XCTAssertEqual(row.currentVersionLabel, version)
    }

    /// A row with no catalog identity keeps today's display, and so does a catalog entry nobody installed.
    func testARowWithNoCatalogIdentityAndANotInstalledCatalogEntryAreNotUnverified() throws {
        let custom = MetagenomicsDatabaseInfo(
            name: "My Custom DB", tool: MetagenomicsTool.kraken2.rawValue, version: "1.0", sizeBytes: 1024,
            description: "", path: URL(fileURLWithPath: "/tmp/custom"), status: .ready, recommendedRAM: 1024
        )
        XCTAssertFalse(custom.isUnverified)
        XCTAssertEqual(custom.checkedVersion, "1.0")
        XCTAssertTrue(PluginManagerViewModel.databaseTrackingSummary(for: custom).contains("Version 1.0"))
        XCTAssertEqual(PluginManagerViewModel.databaseTrackingHelp(for: custom), "")

        let catalog = try XCTUnwrap(MetagenomicsDatabaseInfo.catalogEntry(catalogID: Self.catalogID))
        XCTAssertFalse(catalog.isUnverified, "a catalog entry that is not installed is not a ready row")
        XCTAssertEqual(catalog.checkedVersion, try catalogVersion())
    }

    /// Q-W2. A catalog row that cannot be updated in place (a locally built rRNA index) keeps the first sentence
    /// only, since the second would promise an update that ends in `updateNotSupported`.
    func testAnUnverifiedRowOfALocallyBuiltCatalogEntryKeepsOnlyTheFirstHelpSentence() throws {
        let special = try XCTUnwrap(MetagenomicsDatabaseInfo.builtInCatalog.first {
            if case .kraken2Special = $0.installationRecipe { return true }
            return false
        })
        let row = MetagenomicsDatabaseInfo(
            name: special.name, tool: special.tool, version: nil, sizeBytes: 1024,
            description: "Adopted from a folder", path: URL(fileURLWithPath: "/tmp/special"),
            status: .ready, recommendedRAM: 1024
        )
        XCTAssertEqual(row.resolvedCatalogID, special.catalogID)
        XCTAssertTrue(row.isUnverified)
        XCTAssertEqual(PluginManagerViewModel.databaseTrackingHelp(for: row), Self.firstSentence)
    }

    /// BIO 4. A new classification record made with an unverified database records no database version, where it
    /// recorded the catalog's label. A bound database keeps its version and its digest.
    func testANewClassificationRecordGivesAnUnverifiedDatabaseNoVersion() throws {
        let version = try catalogVersion()
        let sample = MetagenomicsSampleInput(sampleId: "s1", fastq1: URL(fileURLWithPath: "/tmp/s1.fastq"), fastq2: nil)
        func config(for database: MetagenomicsDatabaseInfo) -> ClassificationConfig {
            ClassificationWizardSheet.makeProfileConfig(
                sample: sample, database: database, databasePath: URL(fileURLWithPath: "/tmp/standard-8"),
                outputDirectory: URL(fileURLWithPath: "/tmp/out"), confidence: 0.2, minimumHitGroups: 2, threads: 4,
                memoryMapping: false, extraArguments: []
            )
        }
        XCTAssertEqual(config(for: adoptedRow(version: version)).databaseVersion, "unknown")
        XCTAssertEqual(config(for: adoptedRow(version: nil)).databaseVersion, "unknown")
        let bound = config(for: boundRow(version: version))
        XCTAssertEqual(bound.databaseVersion, version)
        XCTAssertEqual(bound.databaseDigest, "sha256:payload-fixture")
    }
}
