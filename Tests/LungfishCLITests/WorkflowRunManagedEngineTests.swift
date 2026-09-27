// WorkflowRunManagedEngineTests.swift - workflow run launches only the managed engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// `lungfish-cli workflow run nf-core/viralrecon` used to fall back to a
/// Nextflow found on `PATH` (`~/miniforge3/bin/nextflow`, an older release)
/// when the managed copy was missing from the tool root, then failed inside
/// that Nextflow with "nf-schema requires Nextflow >=25.04.0". The CLI now
/// launches only the managed engine and reports a missing one as a
/// missing-tool failure (exit 126) that names Required Setup.
final class WorkflowRunManagedEngineTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var pathDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-managed-engine-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        pathDirectory = root.appendingPathComponent("path-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // A different Nextflow on PATH, as a conda base environment provides.
        _ = try installStubExecutable(named: "nextflow", in: pathDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installStubExecutable(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try "#!/bin/bash\necho stub \(name)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private var pathOnlyEnvironment: [String: String] {
        ["PATH": "\(pathDirectory.path):/usr/bin:/bin", "HOME": home.path]
    }

    func testManagedResolutionRefusesThePATHFallback() throws {
        // The probe still describes the fallback...
        let probe = WorkflowEngineLaunch.resolve(
            executableName: "nextflow", homeDirectory: home, appIdentity: .preview, baseEnvironment: pathOnlyEnvironment)
        XCTAssertFalse(probe.usesManagedExecutable)
        XCTAssertEqual(probe.resolvedExecutableURL()?.path, pathDirectory.appendingPathComponent("nextflow").path)

        // ...but a launch refuses it and says where the managed copy belongs.
        XCTAssertThrowsError(try WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow", homeDirectory: home, appIdentity: .preview, baseEnvironment: pathOnlyEnvironment)
        ) { error in
            guard let missing = error as? WorkflowEngineNotInstalled else {
                return XCTFail("expected WorkflowEngineNotInstalled, got \(error)")
            }
            XCTAssertEqual(missing.executableName, "nextflow")
            XCTAssertEqual(missing.missingToolName, "nextflow")
            XCTAssertTrue(missing.expectedPath.hasPrefix(home.standardizedFileURL.path), missing.expectedPath)
            XCTAssertTrue(missing.expectedPath.hasSuffix("/envs/nextflow/bin/nextflow"), missing.expectedPath)
            let message = try! XCTUnwrap(missing.errorDescription)
            XCTAssertTrue(message.hasPrefix("Nextflow is not installed in Lungfish's managed tool root"), message)
            XCTAssertTrue(message.contains("Required Setup"), message)
            XCTAssertTrue(message.contains("lungfish-cli tools update --apply --yes --required-only"), message)
            XCTAssertTrue(message.contains("PATH is not used"), message)

            let wrapped = CLIError.wrapping(missing)
            guard case .missingTool(let reason) = wrapped else {
                return XCTFail("expected missingTool, got \(wrapped)")
            }
            XCTAssertEqual(wrapped.exitCode.rawValue, 126)
            XCTAssertEqual(reason, message)
        }
    }

    func testManagedResolutionUsesTheManagedCopyWhenPresent() throws {
        let managed = try installStubExecutable(
            named: "nextflow", in: home.appendingPathComponent(".lungfish/conda/envs/nextflow/bin", isDirectory: true))
        let launch = try WorkflowEngineLaunch.resolveManaged(
            executableName: "nextflow", homeDirectory: home, appIdentity: .preview, baseEnvironment: pathOnlyEnvironment)
        XCTAssertTrue(launch.usesManagedExecutable)
        XCTAssertEqual(launch.executableURL.standardizedFileURL.path, managed.standardizedFileURL.path)
        XCTAssertEqual(launch.arguments(["run", "nf-core/viralrecon"]), ["run", "nf-core/viralrecon"])
    }

    /// The process runners take an injectable resolver; with the managed
    /// engine missing, nothing is launched and the runtime is not reported.
    func testProcessRunnersNeverLaunchWithoutTheManagedEngine() async throws {
        let resolver: WorkflowEngineLaunchResolver = { [home = home!, pathDirectory = pathDirectory!] executableName, _ in
            try WorkflowEngineLaunch.resolveManaged(
                executableName: executableName, homeDirectory: home, appIdentity: .preview,
                baseEnvironment: ["PATH": "\(pathDirectory.path):/usr/bin:/bin"])
        }
        let nfCore = ProcessNFCoreWorkflowProcessRunner(homeDirectory: home, resolveLaunch: resolver)
        XCTAssertThrowsError(try nfCore.preflightEngine()) { XCTAssertTrue($0 is WorkflowEngineNotInstalled, "\($0)") }
        do {
            _ = try await nfCore.runNextflow(arguments: ["-version"], workingDirectory: root, environment: [:])
            XCTFail("runNextflow must not fall back to PATH")
        } catch {
            XCTAssertTrue(error is WorkflowEngineNotInstalled, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".nextflow-stdout.log").path))

        let local = ProcessLocalWorkflowProcessRunner(homeDirectory: home, resolveLaunch: resolver)
        XCTAssertNil(local.runtimeExecutableURL(named: "nextflow"))
        do {
            _ = try await local.runWorkflow(executableName: "nextflow", arguments: ["-version"], workingDirectory: root)
            XCTFail("runWorkflow must not fall back to PATH")
        } catch {
            XCTAssertTrue(error is WorkflowEngineNotInstalled, "\(error)")
        }
    }

    /// End to end through the command: the run bundle records the failure
    /// (exit 126) instead of being left "running", and the error keeps its
    /// missing-tool identity for the top-level exit status.
    func testViralReconRunReportsAMissingManagedNextflowAsAMissingTool() async throws {
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2,barcode\nS1,,,1\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)

        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        RunSubcommand.nfCoreWorkflowProcessRunner = ProcessNFCoreWorkflowProcessRunner(
            homeDirectory: home,
            resolveLaunch: { [home = home!, pathDirectory = pathDirectory!] executableName, _ in
                try WorkflowEngineLaunch.resolveManaged(
                    executableName: executableName, homeDirectory: home, appIdentity: .preview,
                    baseEnvironment: ["PATH": "\(pathDirectory.path):/usr/bin:/bin"])
            })
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        let command = try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--param", "platform=nanopore",
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--quiet",
        ])
        do {
            try await command.run()
            XCTFail("a missing managed Nextflow must fail the run")
        } catch {
            XCTAssertTrue(error is WorkflowEngineNotInstalled, "\(error)")
            let wrapped = CLIError.wrapping(error)
            XCTAssertEqual(wrapped.exitCode.rawValue, 126)
        }

        let manifest = try NFCoreRunBundleStore.read(from: runBundleURL)
        XCTAssertEqual(manifest.executionStatus, .failed)
        XCTAssertEqual(manifest.exitCode, 126)
        let stderr = try String(contentsOf: runBundleURL.appendingPathComponent("logs/stderr.log"), encoding: .utf8)
        XCTAssertTrue(stderr.contains("Required Setup"), stderr)
        XCTAssertNotNil(try ProvenanceEnvelopeReader.loadCanonical(from: runBundleURL))
    }
}
