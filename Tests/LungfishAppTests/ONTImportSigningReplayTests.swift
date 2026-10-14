// ONTImportSigningReplayTests.swift - The ONT import keeps its signatures on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6 (the ruling of the A52 whole-lane review, Q6). The cases of
// ONTImportCLIGUIParityReplayTests run with no signing key. This one imports the shared three-barcode run folder
// again with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the
// in-process route under the `legacy` value of its hidden key), side C (the `cli` value, which runs
// `fastq import-ont` on the built CLI) and side C' (the recorded command), and fails when the CLI route leaves
// unsigned a record the in-process route signs, the run folder's record that the result opens first, or the
// record of a barcode bundle that the sidebar lists.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the integration tier.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ONTImportSigningReplayTests: XCTestCase {
    private typealias Family = ONTImportCLIGUIParityReplayTests

    private static let title = "ONT Import: fastq_pass"

    private var scratch: URL!
    private var cliBinary: URL!
    private var harness: RouteParityHarness!

    override func setUp() async throws {
        try await super.setUp()
        // A failed row writes its report, which stays out of the user's ~/Library/Logs.
        OperationCenter.useTemporaryFailureReportsForTesting()
        scratch = try TestTempDirectory.make(prefix: "ont-import-signing")
        cliBinary = try ONTImportFreezeFixture.builtCLI(for: Self.self)
        harness = RouteParityHarness(cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    /// The record of the run folder an import writes, which the result opens first.
    nonisolated static func openingRecord(in root: URL) -> URL {
        Family.project(in: root).appendingPathComponent("Imports/Run1", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// The record of the first barcode bundle the import lists.
    nonisolated static func barcodeRecord(in root: URL) -> URL {
        Family.project(in: root).appendingPathComponent("Imports/Run1/barcode01.lungfishfastq", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    func testAChunkedImportLosesNoSignatureOnTheCLIRoute() async throws {
        let keys = makeKeys()
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("signed", isDirectory: true),
            fixture: Family.writeFixture,
            sideA: { root in
                let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
                    self.startImport(keys: keys.a, root: root)
                }
                return ReadsRouteParity.outcome(of: item)
            },
            sideC: { root in
                let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
                    self.startImport(keys: keys.c, root: root)
                }
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.barcodeRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    /// The key suites of the two sides, side A holding `legacy` and side C holding `cli` at
    /// `ReadsLaunchRoute.ontImport`. Each suite is removed when the test ends.
    private func makeKeys() -> (a: TestDefaultsSuite, c: TestDefaultsSuite) {
        let a = makeTestDefaultsSuite(prefix: "ont-import-signing-a")
        a.defaults.set(ReadsLaunchRoute.legacy.rawValue, forKey: ReadsLaunchPath.ontImport.defaultsKey)
        let c = makeTestDefaultsSuite(prefix: "ont-import-signing-c")
        c.defaults.set(ReadsLaunchRoute.cli.rawValue, forKey: ReadsLaunchPath.ontImport.defaultsKey)
        return (a, c)
    }

    /// Starts the chunked import of the run folder under `root` on a coordinator that reads its route from
    /// `keys`, and returns at once, as the window's task does.
    private func startImport(keys: TestDefaultsSuite, root: URL) {
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: OperationCenter.shared,
            runner: CLIReadsRunner(cliURLOverride: cliBinary),
            routeSettings: ReadsLaunchRouteSettings(defaults: keys.defaults)
        )
        Task { @MainActor in
            _ = try? await coordinator.importDirectory(
                sourceURL: Family.source(in: root), projectURL: Family.project(in: root), includeUnclassified: true,
                concurrency: 1, storageMode: .chunked, routeContext: nil
            )
        }
    }
}
