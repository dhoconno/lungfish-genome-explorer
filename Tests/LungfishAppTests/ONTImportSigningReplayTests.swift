// ONTImportSigningReplayTests.swift - The ONT import keeps its signatures on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6 (the ruling of the A52 whole-lane review, Q6). The cases of
// ONTImportCLIGUIParityReplayTests run with no signing key. This one imports the shared three-barcode run folder
// again with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side C (the
// built CLI's `fastq import-ont`) and side C' (the recorded command), and fails when side C' leaves unsigned a
// record side C signs, or when the run folder's record that the result opens first, or the record of a barcode
// bundle that the sidebar lists, is unsigned on either side. Phase 2.11 (K3) deleted the in-process route that
// was side A.
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
        let runs = try await ReadsRouteParity.runSignedCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("signed", isDirectory: true),
            fixture: Family.writeFixture,
            sideC: { root in
                let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
                    self.startImport(root: root)
                }
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        let sides = [runs.c, runs.cPrime]
        XCTAssertEqual(sides.map(\.outcome.end), [.completed, .completed], sides.map(\.outcome.detail).joined(separator: "\n"))
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.barcodeRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    /// Starts the chunked import of the run folder under `root` on a coordinator that runs the built
    /// command, and returns at once, as the window's task does.
    private func startImport(root: URL) {
        let coordinator = ONTImportOperationCoordinator(
            operationCenter: OperationCenter.shared,
            runner: CLIReadsRunner(cliURLOverride: cliBinary)
        )
        Task { @MainActor in
            _ = try? await coordinator.importDirectory(
                sourceURL: Family.source(in: root), projectURL: Family.project(in: root), includeUnclassified: true,
                concurrency: 1, storageMode: .chunked, routeContext: nil
            )
        }
    }
}
