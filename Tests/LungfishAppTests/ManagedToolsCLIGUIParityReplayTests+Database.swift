// ManagedToolsCLIGUIParityReplayTests+Database.swift - A database update keeps its catalog id, version and digest on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 review, Fix 3 b (BIO 4, panel decision C10, ARCH Q4), as BIO ruled on the first
// run of this case. The Plugin Manager's database update is the third launch the managed tools route
// moves onto the CLI. The registry's `updateDatabase(catalogID:)` computes the catalog id, the version
// and the payload digest of the row, so the row the leaf leaves must carry the values the catalog names.
// The in-process route, which this case once compared the leaf against, went in Phase 2.11 (K3).
//
// The side is `DbCommand.DbUpdateSubcommand.execute(eventsOn:quiet:emit:)`, the leaf, with `registryOverride`
// set to a registry that uses a stand-in archive installer like the one in `ManagedToolLeafFixtures` and
// starts from an installed Viral database, set to an older version through the manifest so that the update
// has a version to move. ManagedToolLeafFixtures is a file of LungfishCLITests, which LungfishAppTests does
// not depend on, so the registry is built here the same way.
//
// `canonicalReceiptSHA256` is bound to the row's own receipt. The case verifies the row against its receipt
// with `MetagenomicsDatabaseConformanceIdentity.verify`. The receipt states the version it moved to. It
// records no version the update started from ("unknown"), since the installed row was registered from disk
// and nothing checked its label.
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
/// row for the name Viral but records no version for a folder it did not check, so the row has no label for
/// an update to move from. The helper states this older label through the manifest and reloads it.
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
        _ = try await registry.seedRowThroughManifest(at: installed, name: "Viral")

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

    func testADatabaseUpdateKeepsCatalogIDVersionAndDigestOnTheCLIRoute() async throws {
        let caseRoot = scratch.appendingPathComponent("database", isDirectory: true)
        let start = try await installedViralRegistry(
            in: RouteParityHarness.root(of: .c, in: caseRoot).appendingPathComponent("databases", isDirectory: true)
        )
        let registry = start.registry
        let installedRow = try await registry.database(named: "Viral")
        let installed = try XCTUnwrap(installedRow)

        // The leaf, on the registry, with the record it writes kept under the case root.
        CondaCommand.storageRootOverride = RouteParityHarness.root(of: .c, in: caseRoot).appendingPathComponent("storage")
        DbCommand.DbUpdateSubcommand.registryOverride = registry
        defer {
            CondaCommand.storageRootOverride = nil
            DbCommand.DbUpdateSubcommand.registryOverride = nil
        }
        let command = try DbCommand.DbUpdateSubcommand.parse(CLIManagedToolsRunner.updateDatabase(catalogID: "kraken2-viral").arguments)
        let ignoreEvents: @Sendable (String) -> Void = { _ in }
        try await command.execute(eventsOn: true, quiet: true, emit: ignoreEvents)

        // The app reloads the manifest the command saved, so it reads its row the same way.
        try await registry.reloadFromDisk()
        let updatedRow = try await registry.database(named: "Viral")
        let row = try XCTUnwrap(updatedRow)

        // The values the route decides, and the row against its own receipt.
        XCTAssertEqual(row.catalogID, "kraken2-viral", "the row proved its catalog identity")
        XCTAssertNotNil(row.payloadDigest, "the update states the digest of the payload it kept")
        _ = try provenIdentity(side: "C", installed: installed, oldPayloadDigest: start.oldPayloadDigest, row: row)

        // The receipt states the update it records.
        let receipt = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: XCTUnwrap(row.path)))
        let options = receipt.options.resolvedDefaults
        XCTAssertEqual(
            options["updatedFromVersion"]?.stringValue, "unknown",
            "the receipt records no from-version for a row nothing checked"
        )
        XCTAssertEqual(
            options["updatedToVersion"]?.stringValue, row.version, "the receipt names the version the update moved to"
        )
    }
}
