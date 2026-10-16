// WorkflowRunOutcomeLinesTests.swift - workflow run prints a Viral Recon run's outcome lines and its Docker wait
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, ARCH's ruling on M3 (commit 4, decision N5). After a run that exits 0 the command reads the
// run's own trace for ignored tasks and its results for failed samples, and prints one warning line for each kind on
// standard error with UX's words, even under --quiet. The Docker wait's two lines reach standard output through the
// runner's progress closure. Each case runs the command in this process on a stand-in runner that writes what a run
// of nf-core/viralrecon 3.0.0 leaves in its results folder (WorkflowRunCapture.swift).

import ArgumentParser
import Foundation
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

final class WorkflowRunOutcomeLinesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The CLI standardizes every path it records (/var -> /private/var).
        root = try TestTempDirectory.make(prefix: "workflow-run-outcome").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var results: URL { root.appendingPathComponent("results", isDirectory: true) }
    private var bundle: URL { root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true) }

    private func run(_ extra: [String] = [], runner: ViralReconStandInRunner) async throws -> WorkflowRunCapture.Captured {
        let arguments = try WorkflowRunCapture.viralReconArguments(root: root) + extra
        let captured = try await WorkflowRunCapture.run(in: root) {
            try await RunSubcommand.parse(arguments).run(nfCoreRunner: runner)
        }
        if let error = captured.error { throw error }
        return captured
    }

    /// A stand-in run in which S2 never reached iVar and Pangolin's task of S1 failed with no retry left.
    func testAStandInRunMissingOneSamplesOutputPrintsTheFailedSampleLine() async throws {
        let trace = "task_id\thash\tname\tstatus\texit\n"
            + "1\taa/000001\tNFCORE_VIRALRECON:VIRALRECON:VARIANTS_IVAR:IVAR_VARIANTS (S1)\tCOMPLETED\t0\n"
            + "2\taa/000002\tNFCORE_VIRALRECON:VIRALRECON:CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S1)\tFAILED\t1\n"

        let output = try await run(runner: ViralReconStandInRunner(results: results, called: ["S1"], trace: trace))

        XCTAssertTrue(
            output.standardError.contains("⚠ Some Viral Recon tasks failed: PANGOLIN_RUN (S1). Their outputs are missing.\n"),
            output.standardError
        )
        XCTAssertTrue(
            output.standardError.contains(
                "⚠ 1 failed sample: S2. Too few reads were left after trimming or mapping to call variants.\n"
            ),
            output.standardError
        )
        XCTAssertEqual(output.standardOutput.split(separator: "\n").last.map(String.init), bundle.path, "the bundle path stays the last line")
    }

    /// Under --quiet the outcome lines still print, as a read pairing warning does, and the wait's lines do not.
    func testTheOutcomeLinesPrintUnderQuietAndTheWaitLinesPrintWithoutIt() async throws {
        let quiet = try await run(["--quiet"], runner: ViralReconStandInRunner(results: results, called: ["S1"]))
        XCTAssertTrue(quiet.standardError.contains("⚠ 1 failed sample: S2."), quiet.standardError)
        XCTAssertFalse(quiet.standardOutput.contains("Docker daemon"), quiet.standardOutput)

        TestTempDirectory.cleanup(root)
        root = try TestTempDirectory.make(prefix: "workflow-run-outcome").resolvingSymlinksInPath()
        let loud = try await run(runner: ViralReconStandInRunner(results: results, called: ["S1", "S2"]))
        XCTAssertTrue(loud.standardOutput.contains("ℹ Docker daemon unavailable. Launching Docker Desktop...\nℹ Docker daemon ready\nℹ Starting the pipeline...\n"), loud.standardOutput)
    }

    /// A run whose samples all reached the caller and whose trace holds no ignored task prints no outcome line.
    func testACleanRunPrintsNoOutcomeLine() async throws {
        let output = try await run(runner: ViralReconStandInRunner(results: results, called: ["S1", "S2"]))
        XCTAssertFalse(output.standardError.contains("⚠"), output.standardError)
    }
}
