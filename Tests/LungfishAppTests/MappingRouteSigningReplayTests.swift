// MappingRouteSigningReplayTests.swift - Map Reads keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6 (the ruling of the A52 whole-lane review, Q6). The case of
// MappingRouteParityReplayTests runs with no signing key. This one maps the same fixture again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side C
// (`runSingleManagedMappingThroughCLI` on the built CLI) and side C' (the recorded command), and fails when the
// CLI route leaves unsigned a record, or the analysis folder's record that the result opens first. Side A, the
// in-process route, went with the mapping key (Phase 2.11 lane A62 M3, K3).
//
// The parity class maps onto a plain FASTA and publishes no viewer bundle, so a second case maps onto a
// `.lungfishref`, the launch from the sidebar, where `MappingViewerBundlePublicationService` rewrites the folder's
// record last (`MappingViewerBundlePublicationSigningReplayTests` is the narrow test of that writer, and holds the
// fixture helpers this class reuses).
//
// minimap2 and samtools are the storage root's own, stated with ToolAvailability, and the class launches the
// built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MappingRouteSigningReplayTests: XCTestCase {
    private typealias Fixture = MappingViewerBundlePublicationSigningReplayTests

    private var scratch: URL!
    private var cliBinary: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "mapping-route-signing")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so sides C and C' cannot run"
        )
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    /// Mapping onto the golden's plain FASTA, which publishes no viewer bundle.
    func testAMappingLosesNoSignatureOnTheCLIRoute() async throws {
        try await assertNoSignatureLost(onReferenceBundle: false)
    }

    /// Mapping onto a `.lungfishref`, the launch from the sidebar. The result then holds the reference viewer
    /// bundle, and `MappingViewerBundlePublicationService` rewrites the analysis folder's record last.
    func testAMappingOntoAReferenceBundleLosesNoSignatureOnTheCLIRoute() async throws {
        try await assertNoSignatureLost(onReferenceBundle: true)
    }

    private func assertNoSignatureLost(onReferenceBundle: Bool) async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let harness = RouteParityHarness(cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await ReadsRouteParity.runSignedCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("signed", isDirectory: true),
            fixture: { root in try Fixture.writeFixture(root, onReferenceBundle: onReferenceBundle) },
            sideC: { root in
                let request = try Fixture.request(in: root, onReferenceBundle: onReferenceBundle)
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (_, item) = try await ReadsRouteParity.record(title: Fixture.title) {
                    Task { @MainActor in
                        await AppDelegate().runSingleManagedMappingThroughCLI(
                            request: request, warning: nil, routeContext: nil,
                            preassignedAnalysisDirectory: request.outputDirectory, runner: runner,
                            cancelBatch: {}, registerCancel: { _ in }
                        )
                    }
                }
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        RouteParityHarness.assertNoSignatureLost(runs, opening: Fixture.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Fixture.openingRecord)
    }
}
