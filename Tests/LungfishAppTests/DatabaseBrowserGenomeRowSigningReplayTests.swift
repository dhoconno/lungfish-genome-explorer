// DatabaseBrowserGenomeRowSigningReplayTests.swift - The NCBI browser's genome row keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L5 (the ruling of the A52 whole-lane review, Q6). The cases of
// DatabaseBrowserGenomeRowParityReplayTests run with no signing key. This one runs its genome row again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the in-process
// route), side C (`fetch genome`) and side C' (the recorded command), and fails when the CLI route leaves
// unsigned a record the in-process route signs, or the bundle's record that the result opens first. Side A
// writes no record, which is the declared difference of that class, so the check on side A is empty.
//
// It launches the built lungfish-cli and the managed bgzip and samtools, so its name ends in ReplayTests and it
// runs in the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class DatabaseBrowserGenomeRowSigningReplayTests: XCTestCase {
    private typealias Family = DatabaseBrowserGenomeRowParityReplayTests

    /// The bundle's record in the project's Downloads folder of a side root. A root with no bundle gives a path
    /// that does not exist, so the assertion reports a missing record.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        let downloads = root.appendingPathComponent("Project.lungfish/Downloads", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
            .filter { $0.hasSuffix(".lungfishref") }
            .sorted()
        return downloads.appendingPathComponent(names.first ?? "no-bundle.lungfishref", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    func testAGenomeRowLosesNoSignatureOnTheCLIRoute() async throws {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        let root = try TestTempDirectory.make(prefix: "genome-row-signing")
        defer { TestTempDirectory.cleanup(root) }
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let records = [Family.record]
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.runSigned(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: Family.makeProject,
            sideA: { try await Family.sideA($0, records: records) },
            sideC: { try await Family.sideC($0, cli: cli, records: records) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }
}
