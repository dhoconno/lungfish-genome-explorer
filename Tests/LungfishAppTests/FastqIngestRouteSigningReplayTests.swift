// FastqIngestRouteSigningReplayTests.swift - The in-place FASTQ ingestion keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6 (the ruling of the A52 whole-lane review, Q6). The case of
// FastqIngestRouteParityReplayTests runs with no signing key. This one ingests the same file again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side C
// (`startInPlaceIngestionThroughCLI` on the built CLI) and side C' (the recorded command), and fails when
// side C' leaves unsigned a record side C signs, or when the folder's record that the result opens first is
// unsigned on either side. Phase 2.11 (K3) deleted the in-process route that was side A.
//
// The stand-in clumpify of that class answers both sides. Side C gets its conda root from LUNGFISH_CONDA_ROOT,
// which this test sets for its run, through the app's subprocess environment, and side C' gets it through the
// harness. It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier.

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
final class FastqIngestRouteSigningReplayTests: XCTestCase {
    private typealias Family = FastqIngestRouteParityReplayTests

    private var scratch: URL!
    private var cliBinary: URL!
    private var savedEnvironment: [String: String?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "fastq-ingest-signing")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so sides C and C' cannot run"
        )
    }

    override func tearDown() async throws {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if !savedEnvironment.isEmpty {
            // The shared runner keeps the path it found for clumpify under the stand-in root.
            await NativeToolRunner.shared.clearCache()
        }
        savedEnvironment = [:]
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    func testAnIngestionLosesNoSignatureOnTheCLIRoute() async throws {
        let condaRoot = scratch.appendingPathComponent("tools/conda", isDirectory: true)
        try ReadsRouteParity.write(Family.copyingClumpify, executableAt: condaRoot.appendingPathComponent("envs/bbtools/bin/clumpify.sh"))
        let environment = ["LUNGFISH_CONDA_ROOT": condaRoot.path, "LUNGFISH_CONDA_SHARED_PKGS": "0"]
        for (key, value) in environment {
            if savedEnvironment[key] == nil { savedEnvironment[key] = .some(ProcessInfo.processInfo.environment[key]) }
            setenv(key, value, 1)
        }
        await NativeToolRunner.shared.clearCache()

        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        let runs = try await ReadsRouteParity.runSignedCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("signed", isDirectory: true),
            fixture: Family.writeFixture,
            sideC: { root in
                let input = Family.input(in: root)
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (_, item) = try await ReadsRouteParity.record(title: Family.title) {
                    FASTQIngestionService.startInPlaceIngestionThroughCLI(url: input, routeContext: nil, runner: runner)
                }
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        let sides = [runs.c, runs.cPrime]
        XCTAssertEqual(sides.map(\.outcome.end), [.completed, .completed], sides.map(\.outcome.detail).joined(separator: "\n"))
        RouteParityHarness.assertNoSignatureLost(runs, opening: Family.record)
        await harness.assertSignaturesVerify(runs, opening: Family.record)
    }
}
