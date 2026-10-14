// DemoProjectsDownloadSigningReplayTests.swift - The Demo Projects download writes no record, so a key signs nothing and loses nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L5 (the ruling of the A52 whole-lane review, Q6). The case of
// DemoProjectsDownloadParityReplayTests runs with no signing key. This one runs its fresh install again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the installer called
// directly), side C (`demo fetch`) and side C' (the recorded command).
//
// The install writes no provenance record of its own. `DemoProjectInstaller` extracts the archive and writes
// `.lgedemo.json`, which is an install note and not a provenance envelope, and no demo source calls a
// `ProvenanceWriter`. The records an archive holds are extracted as the archive holds them, and signing one at
// install time would change bytes the archive states. So the result opens no record of its own to sign, and the
// opening-record rule of `assertNoSignatureLost` has nothing to name. This case holds the other rule for every
// record the install leaves. Each side holds the same records, each signed as on side A, and a key adds no
// signature to the install.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DemoProjectsDownloadSigningReplayTests: XCTestCase {
    private typealias Family = DemoProjectsDownloadParityReplayTests

    /// Every provenance record under `root` by its relative name, with whether it holds a signature and a
    /// public key, and every signature artifact by its relative name.
    private static func records(under root: URL) -> (records: [String: Bool], artifacts: [String]) {
        let base = root.resolvingSymlinksInPath().path + "/"
        var records: [String: Bool] = [:]
        var artifacts: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            if name.hasSuffix(".signature.json") || name.hasSuffix(".pub") {
                artifacts.append(name)
            } else if name.hasSuffix(".json"), url.lastPathComponent.contains("provenance") {
                records[name] = RouteParityHarness.isSigned(url)
            }
        }
        return (records, artifacts.sorted())
    }

    func testAFreshInstallLosesNoSignatureOnTheCLIRoute() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "demo-row-signing")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let standIn = try DemoArchiveStandIn.start(in: root.appendingPathComponent("served", isDirectory: true), payloadBytes: 50_000)
        addTeardownBlock { standIn.stop() }
        var set = standIn.environment
        set[DemoLocationOptions.manifestVariable] = standIn.manifestURL.path
        let saved = ProcessEnvironmentOverride(set: set, unset: ["NCBI_API_KEY"])
        addTeardownBlock { saved.restore() }
        let defaults = makeTestDefaultsSuite(prefix: "DemoProjectsDownloadSigningReplayTests").defaults

        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.runSigned(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: { try FileManager.default.createDirectory(at: Family.installed(in: $0), withIntermediateDirectories: true) },
            sideA: { await Family.installDirectly(in: $0, standIn: standIn) },
            sideC: { await Family.window(in: $0, standIn: standIn, cli: cli, defaults: defaults) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let a = Self.records(under: runs.a.root)
        for run in [runs.c, runs.cPrime] {
            let found = Self.records(under: run.root)
            XCTAssertEqual(found.records, a.records, "side \(run.side) holds other records than side A, or signs them differently")
            XCTAssertEqual(found.artifacts, a.artifacts, "side \(run.side) holds other signature files than side A")
        }
        XCTAssertEqual(a.artifacts, [], "the install signs nothing, since it writes no record of its own")
    }
}
