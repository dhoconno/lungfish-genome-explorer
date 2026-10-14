// AssemblyRouteSigningReplayTests.swift - Reassemble keeps its signature on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6 (the ruling of the A52 whole-lane review, Q6). The case of
// AssemblyRouteParityReplayTests runs with no signing key. This one runs the same Reassemble again with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the in-process
// route), side C (`AssemblyRunner.startManagedAssembly(route: .cli)` on the built CLI) and side C' (the recorded
// command), and fails when the CLI route leaves unsigned a record the in-process route signs, or the reference
// bundle's record that the result opens first.
//
// The stand-in SPAdes of that class answers every side. Its micromamba sits in a conda root of this test's own,
// which also links the storage root's htslib and samtools envs, so the case states bgzip and samtools with
// ToolAvailability. It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
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
final class AssemblyRouteSigningReplayTests: XCTestCase {
    private typealias Family = AssemblyRouteParityReplayTests

    private var scratch: URL!
    private var cliBinary: URL!
    private var savedEnvironment: [String: String?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "assembly-route-signing")
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
            // The shared runner keeps the bgzip and samtools paths it found under the stand-in root.
            await NativeToolRunner.shared.clearCache()
        }
        savedEnvironment = [:]
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    /// The record of the reference bundle Reassemble publishes next to the assembly folder. A root with no bundle
    /// gives a path that does not exist, so the assertion reports a missing record.
    nonisolated static func openingRecord(in root: URL) -> URL {
        Family.assemblyFolder(in: root).deletingLastPathComponent()
            .appendingPathComponent("\(Family.projectName).lungfishref", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    func testAReassembleLosesNoSignatureOnTheCLIRoute() async throws {
        let tools = try await installStandInTools()
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120),
            environment: { _ in tools }
        )
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("signed", isDirectory: true),
            fixture: Family.writeFixture,
            sideA: { root in
                let request = Family.request(in: root)
                let (_, item) = try await ReadsRouteParity.record(title: Family.title) { AssemblyRoute.startInProcess(request) }
                return ReadsRouteParity.outcome(of: item)
            },
            sideC: { root in
                let request = Family.request(in: root).normalizedForExecution()
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (_, item) = try await ReadsRouteParity.record(title: Family.title) {
                    AssemblyRunner.startManagedAssembly(request: request, routeContext: nil, route: .cli, runner: runner)
                }
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    /// A conda root of this test's own: the stand-in micromamba and SPAdes of the parity class, and the storage
    /// root's htslib and samtools envs, linked. Side A reads it from LUNGFISH_CONDA_ROOT, set until tearDown, and
    /// every CLI run gets the returned environment.
    private func installStandInTools() async throws -> [String: String] {
        let bgzip = try await ToolAvailability.require("bgzip", environment: "htslib")
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let condaRoot = scratch.appendingPathComponent("tools/conda", isDirectory: true)
        let envs = condaRoot.appendingPathComponent("envs", isDirectory: true)
        try ReadsRouteParity.write(Family.micromamba(envs: envs), executableAt: condaRoot.appendingPathComponent("bin/micromamba"))
        try ReadsRouteParity.write(Family.spades, executableAt: envs.appendingPathComponent("spades/bin/spades.py"))
        try FileManager.default.createDirectory(at: envs.appendingPathComponent("spades/conda-meta"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: envs.appendingPathComponent("spades/conda-meta/history").path, contents: Data())
        for (name, executable) in [("htslib", bgzip), ("samtools", samtools)] {
            let environment = executable.deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(at: envs.appendingPathComponent(name), withDestinationURL: environment)
        }
        let environment = ["LUNGFISH_CONDA_ROOT": condaRoot.path, "LUNGFISH_CONDA_SHARED_PKGS": "0"]
        for (key, value) in environment {
            if savedEnvironment[key] == nil { savedEnvironment[key] = .some(ProcessInfo.processInfo.environment[key]) }
            setenv(key, value, 1)
        }
        await NativeToolRunner.shared.clearCache()
        return environment
    }
}
