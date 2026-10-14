// ManagedToolsCLIGUIParityReplayTests+Database.swift - A database update keeps its catalog id, version and digest on both routes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 review, Fix 3 b (BIO 4, panel decision C10, ARCH Q4), as BIO ruled on the first
// run of this case. The Plugin Manager's database update is the third launch the managed tools route
// moves onto the CLI. The registry's `updateDatabase(catalogID:)` computes the catalog id, the version
// and the payload digest of the row, and both routes reach that one method, so the row a route leaves
// must carry the same three values.
//
// Side A is `PluginManagerViewModel.updateDatabaseThroughRoute` under
// `ManagedToolsRouteSettings.testOverride = .legacy`, whose `legacy` closure calls registry A. Side C is
// `DbCommand.DbUpdateSubcommand.execute(eventsOn:quiet:emit:)`, the leaf, with `registryOverride` set to
// registry C. Both registries use a stand-in archive installer like the one in `ManagedToolLeafFixtures`
// and start from copies of one installed Viral database, set to an older version through the manifest so
// that the update has a version to move. ManagedToolLeafFixtures is a file of LungfishCLITests, which
// LungfishAppTests does not depend on, so the registry is built here the same way.
//
// `canonicalReceiptSHA256` is bound on each side to its own receipt and is not compared across the sides,
// because the receipt holds the run's own id and clock, so two runs of one route differ on it too. The
// case checks the receipt in three other ways. Each row is verified against its own receipt with
// `MetagenomicsDatabaseConformanceIdentity.verify`, and the two identities are equal on the values the
// route decides. The two database folders, payload and receipt, compare equal under the contract's masks
// (`OutputEquivalence`, kind `.files`). And the receipt of side A states the version the update started
// from and the version it moved to, which the folder comparison carries to side C.
//
// The built CLI has no archive stand-in, so side C' and a cancel through the transport are covered by
// `ManagedToolLeavesLiveConformanceTests`, which runs once with LUNGFISH_REQUIRE_TOOLS=1.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

private let databasePayloadFiles = ["hash.k2d", "opts.k2d", "taxo.k2d"]

/// The version the installed Viral row reads before the update. `registerExisting` adopts the catalog's own
/// row for the name Viral, so a database registered that way already holds the catalog's current label and
/// an update would move nothing. The helper writes this older label through the manifest.
private let installedViralVersion = "20240904"

extension ManagedToolsCLIGUIParityReplayTests {
    /// A registry under `base` holding one installed Viral database whose three files read "old" and whose
    /// row reads `installedViralVersion`, with an archive installer that stages a "new" copy and returns no
    /// archive. `oldPayloadDigest` is the digest of the old files, which the row does not carry because a
    /// row registered from disk has no receipt.
    private func installedViralRegistry(
        in base: URL
    ) async throws -> (registry: MetagenomicsDatabaseRegistry, oldPayloadDigest: String) {
        let installed = base.appendingPathComponent("kraken2/viral", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await registry.loadIfNeeded()
        for name in databasePayloadFiles {
            try "old".write(to: installed.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        _ = try await registry.registerExisting(at: installed, name: "Viral")

        // Set the older version through the manifest and read it again, as a registry that another
        // process changed would.
        let manifestURL = base.appendingPathComponent("metagenomics-db-registry.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var rows = try XCTUnwrap(manifest["databases"] as? [[String: Any]])
        let viral = try XCTUnwrap(rows.firstIndex { $0["name"] as? String == "Viral" }, "the manifest holds a Viral row")
        rows[viral]["version"] = installedViralVersion
        manifest["databases"] = rows
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        try await registry.reloadFromDisk()
        let reloaded = try await registry.database(named: "Viral")
        XCTAssertEqual(reloaded?.version, installedViralVersion, "the reload keeps the older label the update moves")

        let oldPayloadDigest = try MetagenomicsDatabasePayloadDigester.snapshot(at: installed).aggregateSHA256
        await registry.setArchiveInstallerForTesting { _, destination, progress in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in databasePayloadFiles {
                try "new".write(to: destination.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            progress(0.5, "Downloading Viral")
            return nil
        }
        return (registry, oldPayloadDigest)
    }

    /// What a side's row must hold after the update, and the identity its own receipt proves. The row left
    /// the installed version and the old payload digest behind, took the catalog's version and the digest of
    /// the files it kept, and is bound to the receipt in its own folder.
    private func provenIdentity(
        side: String,
        installed: MetagenomicsDatabaseInfo,
        oldPayloadDigest: String,
        row: MetagenomicsDatabaseInfo
    ) throws -> MetagenomicsDatabaseConformanceIdentity {
        XCTAssertNotEqual(row.version, installed.version, "side \(side) moved the version off the installed row")
        XCTAssertEqual(
            row.version, MetagenomicsDatabaseInfo.catalogEntry(catalogID: "kraken2-viral")?.version,
            "side \(side) took the catalog's version"
        )
        XCTAssertNotEqual(row.payloadDigest, oldPayloadDigest, "side \(side) moved the digest off the old payload")
        XCTAssertEqual(
            row.payloadDigest,
            try MetagenomicsDatabasePayloadDigester.snapshot(at: XCTUnwrap(row.path)).aggregateSHA256,
            "side \(side) states the digest of the files it kept"
        )
        XCTAssertNotNil(row.canonicalReceiptSHA256, "side \(side) states the digest of its receipt")
        let identity = try MetagenomicsDatabaseConformanceIdentity.verify(row)
        XCTAssertEqual(
            identity.canonicalReceiptSHA256, row.canonicalReceiptSHA256, "side \(side) row is bound to its own receipt"
        )
        return identity
    }

    func testADatabaseUpdateKeepsCatalogIDVersionAndDigestOnBothRoutes() async throws {
        let caseRoot = scratch.appendingPathComponent("database", isDirectory: true)
        let startA = try await installedViralRegistry(
            in: RouteParityHarness.root(of: .a, in: caseRoot).appendingPathComponent("databases", isDirectory: true)
        )
        let startC = try await installedViralRegistry(
            in: RouteParityHarness.root(of: .c, in: caseRoot).appendingPathComponent("databases", isDirectory: true)
        )
        let registryA = startA.registry
        let registryC = startC.registry
        let installedRowA = try await registryA.database(named: "Viral")
        let installedRowC = try await registryC.database(named: "Viral")
        let installedA = try XCTUnwrap(installedRowA)
        let installedC = try XCTUnwrap(installedRowC)

        // Side A. The Plugin Manager's call on the in-process route, with registry A behind `legacy`.
        ManagedToolsRouteSettings.testOverride = .legacy
        defer { ManagedToolsRouteSettings.testOverride = nil }
        try await PluginManagerViewModel(automaticallyRefresh: false).updateDatabaseThroughRoute(
            catalogID: "kraken2-viral",
            operationID: UUID(),
            legacy: { catalogID, progress in try await registryA.updateDatabase(catalogID: catalogID, progress: progress) },
            registry: registryA,
            progress: { _, _ in }
        )

        // Side C. The leaf, on registry C, with the record it writes kept under the case root.
        CondaCommand.storageRootOverride = RouteParityHarness.root(of: .c, in: caseRoot).appendingPathComponent("storage")
        DbCommand.DbUpdateSubcommand.registryOverride = registryC
        defer {
            CondaCommand.storageRootOverride = nil
            DbCommand.DbUpdateSubcommand.registryOverride = nil
        }
        let command = try DbCommand.DbUpdateSubcommand.parse(["kraken2-viral", "--yes", "--format", "json"])
        let ignoreEvents: @Sendable (String) -> Void = { _ in }
        try await command.execute(eventsOn: true, quiet: true, emit: ignoreEvents)

        let updatedRowA = try await registryA.database(named: "Viral")
        let updatedRowC = try await registryC.database(named: "Viral")
        let rowA = try XCTUnwrap(updatedRowA)
        let rowC = try XCTUnwrap(updatedRowC)
        func facts(_ row: MetagenomicsDatabaseInfo) -> String {
            "catalogID \(row.catalogID ?? "nil"), version \(row.version ?? "nil"), payloadDigest \(row.payloadDigest ?? "nil")"
        }
        let both = "A: \(facts(rowA)) | C: \(facts(rowC))"

        // The three values the route decides.
        XCTAssertEqual(rowA.catalogID, "kraken2-viral", "the row proved its catalog identity: \(both)")
        XCTAssertEqual(rowA.catalogID, rowC.catalogID, "catalogID: \(both)")
        XCTAssertEqual(rowA.version, rowC.version, "version: \(both)")
        XCTAssertNotNil(rowA.payloadDigest, "the update states the digest of the payload it kept")
        XCTAssertEqual(rowA.payloadDigest, rowC.payloadDigest, "payloadDigest: \(both)")

        // Each row against its own receipt, then the two identities on the values the route decides. Path,
        // receipt digest and retrieval time vary with the root, the run and the clock, so they are not compared.
        let identityA = try provenIdentity(
            side: "A", installed: installedA, oldPayloadDigest: startA.oldPayloadDigest, row: rowA
        )
        let identityC = try provenIdentity(
            side: "C", installed: installedC, oldPayloadDigest: startC.oldPayloadDigest, row: rowC
        )
        func decided(_ identity: MetagenomicsDatabaseConformanceIdentity) -> [String: String] {
            [
                "catalogID": identity.catalogID ?? "nil",
                "catalogVersion": identity.catalogVersion ?? "nil",
                "installedVersion": identity.installedVersion ?? "nil",
                "payloadAggregateSHA256": identity.payloadAggregateSHA256,
                "sourcePolicy": identity.sourcePolicy,
                "requestedSourceURL": identity.requestedSourceURL ?? "nil",
                "receivedArchiveSHA256": identity.receivedArchiveSHA256 ?? "nil",
            ]
        }
        let decidedA = decided(identityA)
        let decidedC = decided(identityC)
        for key in decidedA.keys.sorted() {
            XCTAssertEqual(decidedA[key], decidedC[key], "identity \(key): A \(decidedA[key] ?? "nil") | C \(decidedC[key] ?? "nil")")
        }

        // The two folders, payload and receipt, under the contract's masks. The receipt is read as written
        // apart from the values the provenance masks hide: ids, dates, wall time, the executable and the roots.
        let folderDifferences = try OutputEquivalence.differences(
            XCTUnwrap(rowA.path), XCTUnwrap(rowC.path), kind: .files
        )
        XCTAssertEqual(
            folderDifferences, [], "the database folders differ under the contract's masks: \(folderDifferences)"
        )

        // The receipt states the update it records, so two equal receipts cannot both be wrong the same way.
        let receiptA = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: XCTUnwrap(rowA.path)))
        let options = receiptA.options.resolvedDefaults
        XCTAssertEqual(
            options["updatedFromVersion"]?.stringValue, installedViralVersion,
            "the receipt names the version the update started from"
        )
        XCTAssertEqual(
            options["updatedToVersion"]?.stringValue, rowA.version, "the receipt names the version the update moved to"
        )
    }
}
