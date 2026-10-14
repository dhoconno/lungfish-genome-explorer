// ManagedToolLeavesSIGTERMTests.swift - SIGTERM cancels tools update and conda install --pack on the built CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Phase 2.10 lane A52 M2 (family L10, panel decisions P2 and G1). The Update Tools sheet and the
/// Plugin Manager cancel `tools update --apply --only` and `conda install --pack --reinstall` with
/// SIGTERM. `ManagedToolLeavesTests` checks the conversion in the test process. These tests send the
/// signal to the built `lungfish-cli` on `CLISIGTERMHarness`, with a stand-in micromamba under a
/// conda root of their own, a home and a storage root of their own. The stand-in records its pid and
/// starts a child that stands in for micromamba's workers, then waits.
///
/// The CLI is signaled alone, as `kill <pid>` does. `CondaManager` runs micromamba to its end when its
/// caller is cancelled, so a leaf that only cancelled its task waited for micromamba and missed the
/// 6 seconds the app gives it. Each leaf now also stops the tools of its run when SIGTERM arrives.
final class ManagedToolLeavesSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "managed-tool-leaves-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The folders and pid files of one run, and the environment that points the CLI at them.
    private struct Sandbox {
        let storageRoot: URL
        let toolPIDFile: URL
        let childPIDFile: URL
        let calls: URL
        let environment: [String: String]
    }

    private func makeSandbox() throws -> Sandbox {
        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let condaRoot = storageRoot.appendingPathComponent("conda", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [condaRoot.appendingPathComponent("bin", isDirectory: true), home] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let toolPIDFile = root.appendingPathComponent("micromamba.pid")
        let childPIDFile = root.appendingPathComponent("worker.pid")
        let calls = root.appendingPathComponent("micromamba-calls.txt")

        // The version probe answers as the lock's bootstrap does, so the plan holds no bootstrap
        // step. Every other call is an environment operation, which the stand-in never finishes.
        let lockVersion = ManagedToolLock.bundled.bootstrap?.micromamba.version ?? "2.9.0-0"
        let version = lockVersion.split(separator: "-").first.map(String.init) ?? lockVersion
        let micromamba = condaRoot.appendingPathComponent("bin/micromamba")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "\(version)"; exit 0; fi
        echo "$@" >> "\(calls.path)"
        echo $$ > "\(toolPIDFile.path)"
        /bin/sh -c 'echo $$ > "\(childPIDFile.path)"; exec /bin/sleep 300' &
        wait
        """.write(to: micromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)

        return Sandbox(
            storageRoot: storageRoot,
            toolPIDFile: toolPIDFile,
            childPIDFile: childPIDFile,
            calls: calls,
            environment: [
                "LUNGFISH_STORAGE_ROOT": storageRoot.path,
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
            ]
        )
    }

    /// Starts the CLI, waits until the stand-in micromamba is at work, sends SIGTERM to the CLI alone
    /// and asserts the three facts of a converted cancel on `CLISIGTERMHarness`. Returns the stop and
    /// the processes of the stand-in, which the CLI's tree must have held.
    private func assertCancels(
        _ arguments: [String],
        recordFolder: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (stop: CLISIGTERMHarness.Stop, sandbox: Sandbox) {
        let sandbox = try makeSandbox()
        let cli = try CLISIGTERMHarness.launchCLI(
            arguments,
            environment: sandbox.environment,
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }

        guard let toolPID = await CLISIGTERMHarness.waitForProcessID(in: sandbox.toolPIDFile),
              let childPID = await CLISIGTERMHarness.waitForProcessID(in: sandbox.childPIDFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            XCTFail("The CLI never ran micromamba.\(stop.diagnostics)", file: file, line: line)
            return (stop, sandbox)
        }
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(
            cli,
            record: { try ManagedToolLeafFixtures.recordStatus(storageRoot: sandbox.storageRoot, folder: recordFolder) },
            file: file,
            line: line
        )
        XCTAssertTrue(
            stop.tree.contains(toolPID) && stop.tree.contains(childPID),
            "micromamba and its worker belong to the CLI's tree \(stop.tree)",
            file: file, line: line
        )
        return (stop, sandbox)
    }

    /// The last event a command printed on standard output, nil when it printed none.
    private func lastEvent(_ standardOutput: String) -> CLIEvent? {
        standardOutput.split(separator: "\n").last.flatMap { try? CLIEventLineDecoder().decode(line: String($0)) }
    }

    func testSIGTERMCancelsAToolsUpdateAndStopsMicromamba() async throws {
        let (stop, sandbox) = try await assertCancels(
            ["tools", "update", "--apply", "--yes", "--only", "samtools", "--format", "json"],
            recordFolder: "dependencies"
        )

        let calls = (try? String(contentsOf: sandbox.calls, encoding: .utf8)) ?? ""
        XCTAssertTrue(calls.hasPrefix("create -n "), "the run was creating an environment: \(calls)")
        guard case .failed(let message, _)? = lastEvent(stop.standardOutput) else {
            return XCTFail("the run ends with a failed event: \(stop.standardOutput)")
        }
        XCTAssertTrue(message.lowercased().contains("cancelled"), message)
    }

    func testSIGTERMCancelsAPackReinstallAndStopsMicromamba() async throws {
        let (stop, sandbox) = try await assertCancels(
            ["conda", "install", "--pack", "read-mapping", "--reinstall", "--format", "json"],
            recordFolder: "packs"
        )

        let calls = (try? String(contentsOf: sandbox.calls, encoding: .utf8)) ?? ""
        XCTAssertTrue(calls.contains("create") || calls.contains("install"), "the run was installing: \(calls)")
        guard case .failed(let message, _)? = lastEvent(stop.standardOutput) else {
            return XCTFail("the run ends with a failed event: \(stop.standardOutput)")
        }
        XCTAssertTrue(message.lowercased().contains("cancelled"), message)
    }
}
