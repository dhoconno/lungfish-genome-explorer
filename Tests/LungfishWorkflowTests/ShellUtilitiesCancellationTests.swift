// ShellUtilitiesCancellationTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// NEW-08: a classifier operation (EsViritu, Kraken2, ...) cancelled while
/// `detectToolVersion` has a version probe in flight stayed in
/// `OperationCenter`'s active list forever, even though the probe's process
/// tree was correctly terminated. `detectToolVersion` used to catch every
/// error from `condaManager.runTool` (including `CancellationError`) and
/// silently retry the next `--version`/`-v` flag, so a cancelled task's
/// pipeline (`EsVirituPipeline.detect`, `ClassificationPipeline.classify`,
/// ...) kept running instead of throwing, and none of those pipelines check
/// `Task.isCancelled` again until their own next tool invocation -- which
/// for a fast pre-tool stage can be long past the point OperationCenter
/// expected a terminal state.
///
/// This test drives `detectToolVersion` directly against a fake
/// `micromamba` that blocks the version probe forever, cancels the
/// enclosing task, and asserts the call surfaces `CancellationError`
/// promptly instead of swallowing it and returning "unknown".
final class ShellUtilitiesCancellationTests: XCTestCase {

    /// A `CondaManager` rooted at a scratch directory whose `bin/micromamba`
    /// is a tiny shell script: `--version` (the manager's own self-check)
    /// answers instantly, but `run -n <env> <tool> ...` (the actual probe
    /// `detectToolVersion` launches) blocks until killed, so a cancellation
    /// mid-probe is fully deterministic.
    private func makeFixture() throws -> (condaManager: CondaManager, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellutil-cancel-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let micromambaPath = binDir.appendingPathComponent("micromamba")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            echo "1.5.0"
            exit 0
        fi
        # "run -n <env> <tool> <flag>": block until signalled, simulating a
        # slow/hanging tool probe that only process-tree termination stops.
        trap 'exit 143' TERM
        while true; do sleep 3600 & wait $!; done
        """
        try script.write(to: micromambaPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromambaPath.path)

        let condaManager = CondaManager(rootPrefix: root)
        return (condaManager, root)
    }

    /// Cancelling the enclosing task while a version probe is blocked must
    /// surface `CancellationError` from `detectToolVersion` itself -- not
    /// "unknown" after quietly absorbing the cancellation and trying the
    /// next flag -- so the calling pipeline's own `catch` reaches
    /// `OperationCenter.fail`/`.acknowledgeCancellation` instead of running
    /// on past the point the user cancelled.
    func testDetectToolVersionRethrowsCancellationInsteadOfReturningUnknown() async throws {
        let (condaManager, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task<String, Error> {
            try await detectToolVersion(
                toolName: "EsViritu",
                environment: "esviritu",
                condaManager: condaManager,
                flags: ["--version", "-v"],
                timeout: 30
            )
        }

        // Give the probe a moment to actually launch the blocking subprocess
        // before cancelling, so this exercises real mid-flight cancellation
        // rather than a task cancelled before it ever started.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            let result = try await task.value
            XCTFail("Expected CancellationError, got success with '\(result)'")
        } catch is CancellationError {
            // Expected: cancellation must be rethrown, not swallowed.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
