// TaxTriageEngineProcess.swift - The launch, cancel, scratch and output lines of TaxTriage's Nextflow engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "TaxTriagePipeline")

// MARK: - TaxTriageEngineProcess

/// Runs TaxTriage's Nextflow engine for ``TaxTriagePipeline`` and streams its output lines.
///
/// A cancel of the calling task stops the whole engine tree on the host, the launcher, Nextflow's
/// JVM and every task wrapper (Phase 2.8 decision T11). ToolProcess sends TERM to the process group
/// and the descendant tree, then KILL to whatever is left after ``terminationGracePeriod`` (T12),
/// and ``run(executable:arguments:workingDirectory:environment:onStdoutLine:)`` returns only once
/// the tree is gone. So nothing the caller removes afterwards, the launch scratch with `work/`
/// among it (T13), goes while the engine runs. Containers run by Docker are outside the host tree
/// and are not stopped here.
struct TaxTriageEngineProcess: Sendable {
    /// Nextflow's grace on the in-process route, the same 4 s it has inside the CLI's 6 s on the
    /// CLI route (T12). It ends well inside the 10 s OperationCenter gives a cancelled row, so the
    /// row settles from the worker.
    static let defaultTerminationGracePeriod: Duration = .seconds(4)

    /// How the engine ended, read once its whole tree is gone.
    struct Outcome: Sendable {
        /// The exit status, the number of the signal that ended the engine, or -1 when none was
        /// reported. A cancel is read from the task, never from this.
        let exitCode: Int32
        let stdoutLines: [String]
        let stderrLines: [String]
    }

    let processManager: ProcessManager
    let terminationGracePeriod: Duration

    init(processManager: ProcessManager, terminationGracePeriod: Duration = Self.defaultTerminationGracePeriod) {
        self.processManager = processManager
        self.terminationGracePeriod = terminationGracePeriod
    }

    /// Launches the engine, hands each stdout line to `onStdoutLine` as it arrives, and returns once
    /// the engine and every process of its tree have ended, after a cancel too.
    ///
    /// - Throws: The launch failure. Nothing runs then.
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> Outcome {
        let (handle, stop) = try await processManager.spawnStoppable(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            terminationGracePeriod: terminationGracePeriod
        )
        logger.info("Nextflow process started with PID \(handle.pid)")

        // Not a child task, so a cancel of the caller ends neither the reads nor the wait early
        // (inventory T4). The streams end only once the run is over and the tree is gone.
        let streaming = Task {
            async let stdout = Self.lines(of: handle.standardOutput, onLine: onStdoutLine)
            async let stderr = Self.lines(of: handle.standardError, onLine: nil)
            let lines = await (stdout, stderr)
            return Outcome(exitCode: await handle.waitForExit(), stdoutLines: lines.0, stderrLines: lines.1)
        }
        return await withTaskCancellationHandler {
            await streaming.value
        } onCancel: {
            // Runs at once when the task was cancelled during the launch, so no cancel is lost. It
            // stops the run on the cancelling thread, as runAndWait does, so the TERM and the KILL
            // after the grace never wait for the cooperative pool or the actor.
            stop()
        }
    }

    /// Every line of `stream`, each handed to `onLine` as it arrives.
    private static func lines(
        of stream: AsyncStream<String>,
        onLine: (@Sendable (String) -> Void)?
    ) async -> [String] {
        var lines: [String] = []
        for await line in stream {
            lines.append(line)
            onLine?(line)
        }
        return lines
    }
}

// MARK: - Engine

extension TaxTriagePipeline {
    /// Set to `1` to keep the Nextflow launch scratch (including `work/`) after a run, the key
    /// ``NextflowWorkflowDescriptor/taxTriage`` names.
    static let keepWorkEnvironmentKey = "LUNGFISH_TAXTRIAGE_KEEP_WORK"

    /// TaxTriage's Nextflow engine for a launch with the effective `profile`, the shared engine
    /// process with the settings of ``NextflowWorkflowDescriptor/taxTriage`` (Phase 2.9, N2).
    ///
    /// The engine waits for Docker only for the `docker` profile, gives the tree 4 s between TERM
    /// and KILL, and names the scratch `taxtriage-run-` with the keep-work key (N6, N7, N9).
    static func nextflowEngine(processManager: ProcessManager, profile: String) -> NextflowEngineProcess {
        NextflowEngineProcess(
            processManager: processManager,
            configuration: NextflowWorkflowDescriptor.taxTriage.engineConfiguration(profile: profile)
        )
    }

    // MARK: - Local launch scratch

    /// A local, lock-capable scratch for one launch, as a run makes it with its engine, the launch
    /// folder that hosts Nextflow's `.nextflow/` cache and history and the `-w` work folder (N7).
    ///
    /// The scratch stays on the project volume whenever it can host Nextflow's cache, since external
    /// project drives are usually far larger than the boot volume and multi-GB work trees belong
    /// there. Only a disqualified volume, one without `fcntl` locks or one whose AppleDouble sidecars
    /// crash the LevelDB cache (ExFAT through FSKit, some network mounts), forces local storage. See
    /// ``NextflowScratchVolumeProbe``.
    nonisolated func makeLocalLaunchScratch(
        contextURL: URL,
        volumeQualifiesForScratch: Bool? = nil
    ) throws -> NextflowEngineScratch {
        try Self.nextflowEngine(processManager: .shared, profile: NextflowWorkflowDescriptor.taxTriage.profile)
            .makeScratch(contextURL: contextURL, volumeQualifiesForScratch: volumeQualifiesForScratch)
    }

    /// Removes a scratch from ``makeLocalLaunchScratch(contextURL:volumeQualifiesForScratch:)`` once
    /// the run's record is written, unless it is kept for debugging.
    nonisolated func cleanUpLaunchScratch(_ scratch: NextflowEngineScratch) {
        Self.nextflowEngine(processManager: .shared, profile: NextflowWorkflowDescriptor.taxTriage.profile)
            .finish(scratch, .remove)
    }
}
