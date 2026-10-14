// NextflowWorkflowContractParityReplayTests+DockerWait.swift - A Viral Recon run whose Docker wait fails
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M2, SWIFT's Docker wait (2.9 N9) on the route, through Q33 R4's stand-in. The docker profile
// waits for the daemon after the preflight and before the run bundle is marked running. When the daemon does not
// answer and Docker Desktop cannot be started, the wait fails at once, the engine never starts, and the run bundle
// records the failure with the container exit code. A pin of the route as M2 built it, so it passes at its base.

import Foundation
@testable import LungfishCLI
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

extension NextflowWorkflowContractParityReplayTests {
    /// The stand-in's `version` exits 1, as a stopped daemon answers, and it refuses `-g -a Docker`, as a Docker
    /// Desktop that cannot start does. The run fails at once with 65, launches nothing and records the failure.
    func testAFailedDockerWaitRecordsAFailedRunAndLaunchesNothing() throws {
        let standIn = root.appendingPathComponent("docker-down/docker-standin", isDirectory: true)
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: true)
        try Data().write(to: standIn.appendingPathComponent("daemon-down"))

        let run = try runRoute(.docker, case: "docker-down")

        XCTAssertEqual(run.status, CLIExitCode.containerError.rawValue, run.stderr)
        XCTAssertTrue(run.launches.isEmpty, "the engine never starts")
        XCTAssertEqual(dockerStandInCalls(case: "docker-down"), [
            "version --format {{.Client.Version}}|{{if .Server}}{{.Server.Version}}{{end}}",
            "-g -a Docker",
        ], "the wait asks the daemon once and starts Docker Desktop through the stand-in only")
        let bundle = root.appendingPathComponent("docker-down/Project/Analyses/viralrecon.lungfishrun", isDirectory: true)
        let manifest = try NFCoreRunBundleStore.read(from: bundle)
        XCTAssertEqual(manifest.executionStatus, .failed)
        XCTAssertEqual(manifest.exitCode, CLIExitCode.containerError.rawValue)
        XCTAssertEqual(manifest.stderrLogPath, "logs/stderr.log")
        let stderr = try String(contentsOf: bundle.appendingPathComponent("logs/stderr.log"), encoding: .utf8)
        XCTAssertTrue(stderr.contains("Docker"), stderr)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle), "no provenance for the failed run")
        XCTAssertEqual(provenance.status, .failed)
        XCTAssertEqual(provenance.steps.first?.exitStatus, Int(CLIExitCode.containerError.rawValue))
    }
}
