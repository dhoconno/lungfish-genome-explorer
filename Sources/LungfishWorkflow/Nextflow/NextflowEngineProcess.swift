// NextflowEngineProcess.swift - The one launch path of a Nextflow engine, with its cancel, scratch and log
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "NextflowEngineProcess")

// MARK: - NextflowEngineProcess

/// Runs one Nextflow engine tree and returns only once the tree is gone. Every Nextflow workflow
/// launches through it (Phase 2.9, decisions N2 and N10).
///
/// - A cancel of the calling task stops the whole host tree, the launcher, Nextflow's JVM and every
///   task wrapper, with TERM and then KILL after the configuration's grace, 4 s for every Nextflow
///   engine (N6). ``run(_:in:hooks:)`` returns only once the tree is gone, after it has stopped the
///   run's task containers through the cleanup hook, never past ``containerCleanupBound`` (N5).
/// - The caller writes its `cancelled` record after ``run(_:in:hooks:)`` returns and only then calls
///   ``finish(_:_:)``, so the scratch, `work/` among it, never goes before the record (N5, N7).
/// - Each stdout line goes into `nextflow.log` as it arrives, a bounded tail stays in memory, and the
///   log is synchronized at its final name before ``run(_:in:hooks:)`` returns (N8).
/// - ``waitForDocker(probe:progress:)`` waits for the Docker daemon, ends at once on a cancel and fails
///   at once when Docker Desktop cannot be started (N9).
///
/// Containers run in Docker Desktop's VM outside the host tree. Only the cleanup hook reaches them.
package struct NextflowEngineProcess: Sendable {
    /// The grace between TERM and KILL for every Nextflow engine (N6). Nextflow stops its tasks and
    /// finishes its own shutdown in it, 1.8 s on a real cancel (Q15 R3), and the grace plus
    /// ``containerCleanupBound`` ends inside the 6 s the GUI gives a cancelled CLI command.
    package static let terminationGracePeriod: Duration = .seconds(4)

    /// The longest a cancelled run waits for its container cleanup once the host tree is gone (N5).
    package static let containerCleanupBound: Duration = .milliseconds(1500)

    package let processManager: ProcessManager
    package let configuration: NextflowEngineConfiguration
    /// How ``waitForDocker(probe:progress:)`` polls and starts Docker Desktop. A test sets its own, so
    /// it never starts Docker Desktop.
    package var dockerWait: NextflowDockerWait = .standard

    package init(processManager: ProcessManager = .shared, configuration: NextflowEngineConfiguration) {
        self.processManager = processManager
        self.configuration = configuration
    }

    // MARK: Scratch

    /// Creates a run's scratch, the launch folder that holds Nextflow's `.nextflow/` cache and its
    /// `work/` folder (N7).
    ///
    /// The scratch stays on the volume of `contextURL` when that volume can host Nextflow's cache,
    /// since an external project drive is usually far larger than the boot volume. A volume without
    /// `fcntl` locks, or one that adds AppleDouble sidecars, such as ExFAT through FSKit, puts it in
    /// the system temp folder (``NextflowScratchVolumeProbe``). With the configuration's keep-work key
    /// set to `1` the scratch has no removal root, so ``finish(_:_:)`` keeps it for debugging.
    ///
    /// - Parameters:
    ///   - volumeQualifiesForScratch: The probe's answer, asked of the volume when nil.
    ///   - environment: Where the keep-work key is read.
    package func makeScratch(
        contextURL: URL,
        volumeQualifiesForScratch: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> NextflowEngineScratch {
        let scratchCapable = volumeQualifiesForScratch
            ?? NextflowScratchVolumeProbe.volumeSupportsNextflowScratch(at: contextURL)
        let root = try ProjectTempDirectory.create(
            prefix: configuration.scratchPrefix,
            contextURL: contextURL,
            policy: scratchCapable ? .preferProjectContext : .systemOnly
        )
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let keepsWork = configuration.keepWorkEnvironmentKey.map { environment[$0] == "1" } ?? false
        if keepsWork {
            logger.info("Keeping the Nextflow launch scratch at \(root.path, privacy: .public)")
        }
        return NextflowEngineScratch(launchDirectory: root, workDirectory: workDirectory, removalRoot: keepsWork ? nil : root)
    }

    /// Removes the scratch or leaves it, once the caller's record is written (N5, N7). A CLI run
    /// that was cancelled leaves it for the abandoned-scratch sweep, and every other run removes it.
    /// A scratch kept for debugging is never removed.
    package func finish(_ scratch: NextflowEngineScratch, _ disposition: NextflowScratchDisposition) {
        guard disposition == .remove, let removalRoot = scratch.removalRoot else { return }
        do {
            try FileManager.default.removeItem(at: removalRoot)
        } catch {
            logger.warning(
                "Could not remove the Nextflow launch scratch \(removalRoot.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Run

    /// Launches the engine in the scratch's launch folder, streams its output into the log and
    /// returns once the engine and every process of its tree have ended, after a cancel too.
    ///
    /// The log at the launch's `logFile` holds the preamble, then `--- stdout ---` and each stdout
    /// line as it arrives, then `--- stderr ---` and the stderr lines, which wait in a sidecar in the
    /// scratch until the engine has ended. These are the bytes TaxTriage wrote once its engine had
    /// returned. A KILL of the calling process leaves the preamble and the stdout so far. A launch
    /// that fails leaves the preamble and a `--- launcher error ---` part.
    ///
    /// A cancel is read from the task. After a cancel the outcome reports how the stopped engine
    /// ended, and the cleanup hook has stopped the run's containers or run out its bound. The caller
    /// then writes its `cancelled` record and calls ``finish(_:_:)``. A write of the log that failed
    /// while the engine ran is in the outcome's `logFailure`, and the caller fails the run on it.
    ///
    /// - Throws: `CancellationError` when the task was cancelled before the spawn, with nothing
    ///   launched and no log written (E10). ``NextflowEngineError/logNotWritable(path:reason:)`` when
    ///   the log cannot be created, with nothing launched. The launch failure, with the log written.
    package func run(
        _ launch: NextflowEngineLaunch,
        in scratch: NextflowEngineScratch,
        hooks: NextflowEngineHooks
    ) async throws -> NextflowEngineOutcome {
        try Task.checkCancellation()
        var log = try NextflowEngineLog.create(
            at: launch.logFile,
            preamble: launch.logPreamble,
            stderrSidecar: scratch.launchDirectory.appendingPathComponent(NextflowEngineLog.stderrSidecarName),
            tailLineCount: configuration.logTailLineCount
        )
        let handle: ProcessHandle
        let stop: @Sendable () -> Void
        do {
            (handle, stop) = try await processManager.spawnStoppable(
                executable: launch.executable,
                arguments: launch.arguments,
                workingDirectory: scratch.launchDirectory,
                environment: launch.environment,
                terminationGracePeriod: configuration.terminationGracePeriod
            )
        } catch {
            log.finish(launchFailure: Self.launchFailureMessage(for: error))
            throw error
        }
        logger.info("Nextflow engine started with PID \(handle.pid)")
        log.beginStdout()

        let progress = hooks.progress
        let tracePoll = launch.traceFile.flatMap { traceFile in
            progress.map { Self.pollTrace(traceFile, every: configuration.tracePollInterval, reporter: $0) }
        }
        // Not a child task, so a cancel of the caller ends neither the reads nor the wait early. The
        // streams end only once the run is over and the tree is gone.
        let stdoutPart = log.stdoutStream()
        let stderrPart = log.stderrStream()
        let streaming = Task {
            async let stdout = stdoutPart.drained(handle.standardOutput) { line in progress?.engineLine(line) }
            async let stderr = stderrPart.drained(handle.standardError, onLine: nil)
            let parts = await (stdout, stderr)
            return (exitCode: await handle.waitForExit(), stdout: parts.0, stderr: parts.1)
        }
        let ended = await withTaskCancellationHandler {
            await streaming.value
        } onCancel: {
            // Runs at once when the task was cancelled during the launch, so no cancel is lost. It
            // stops the run on the cancelling thread, so the TERM and the KILL after the grace never
            // wait for the cooperative pool or the actor.
            stop()
        }

        if let tracePoll, let traceFile = launch.traceFile, let progress {
            tracePoll.cancel()
            let lastReading = await tracePoll.value
            _ = Self.reportTrace(at: traceFile, to: progress, after: lastReading)
        }
        let logFailure = log.finish(stdout: ended.stdout, stderr: ended.stderr)

        // N5. The host tree is gone, so the run's task containers stop next, before the caller's
        // record and long before its scratch goes.
        if Task.isCancelled, let cleanup = hooks.cleanup {
            await Self.stopContainers(with: cleanup, boundTo: scratch.workDirectory, within: Self.containerCleanupBound)
        }
        return NextflowEngineOutcome(
            exitCode: ended.exitCode,
            stdoutTail: ended.stdout.tail,
            stderrTail: ended.stderr.tail,
            logFile: launch.logFile,
            logFailure: logFailure
        )
    }

    /// The words a failed launch leaves in the log and in the caller's record.
    package static func launchFailureMessage(for error: any Error) -> String {
        "Failed to spawn Nextflow: \(error.localizedDescription)"
    }

    /// Reads the trace file every `interval` and hands the reporter each new reading, until it is
    /// cancelled. Returns the last reading it handed over.
    private static func pollTrace(
        _ traceFile: URL,
        every interval: Duration,
        reporter: any NextflowProgressReporting
    ) -> Task<NextflowTraceProgress?, Never> {
        Task.detached {
            var lastReading: NextflowTraceProgress?
            while true {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return lastReading
                }
                lastReading = reportTrace(at: traceFile, to: reporter, after: lastReading)
            }
        }
    }

    /// Hands the reporter the trace file's reading when it differs from `lastReading`, and returns the
    /// reading the reporter last had.
    private static func reportTrace(
        at traceFile: URL,
        to reporter: any NextflowProgressReporting,
        after lastReading: NextflowTraceProgress?
    ) -> NextflowTraceProgress? {
        guard let reading = NextflowTraceProgress(traceFileAt: traceFile), reading != lastReading else {
            return lastReading
        }
        reporter.traceProgress(reading)
        return reading
    }
}

// MARK: - Engine values

/// One workflow's engine settings, a 4 s grace, a 200-line tail and a 5 s trace poll by default
/// (N6, N8, W2).
package struct NextflowEngineConfiguration: Sendable, Equatable {
    /// The scratch folder's name prefix, such as `taxtriage-run-`.
    package var scratchPrefix: String
    /// The environment variable that keeps the scratch when set to `1`, or nil for none.
    package var keepWorkEnvironmentKey: String?
    /// Whether this launch's effective profile runs its tasks in Docker, so that
    /// ``NextflowEngineProcess/waitForDocker(probe:progress:)`` waits for the daemon (N9). Set it through
    /// `NextflowWorkflowDescriptor.engineConfiguration(profile:)` for the profile the run uses, never from
    /// `containerRuntime` alone (A16 M1 review, ruling 2). A conda run and a stand-in run never wait.
    package var waitsForDocker: Bool
    package var terminationGracePeriod: Duration
    /// How many of the last lines of each stream the outcome keeps.
    package var logTailLineCount: Int
    package var tracePollInterval: Duration

    package init(
        scratchPrefix: String,
        keepWorkEnvironmentKey: String?,
        waitsForDocker: Bool,
        terminationGracePeriod: Duration = NextflowEngineProcess.terminationGracePeriod,
        logTailLineCount: Int = 200,
        tracePollInterval: Duration = .seconds(5)
    ) {
        self.scratchPrefix = scratchPrefix
        self.keepWorkEnvironmentKey = keepWorkEnvironmentKey
        self.waitsForDocker = waitsForDocker
        self.terminationGracePeriod = terminationGracePeriod
        self.logTailLineCount = logTailLineCount
        self.tracePollInterval = tracePollInterval
    }
}

/// One launch, such as `micromamba run -n nextflow nextflow run ...` for TaxTriage, with the log at
/// its final name and the trace file to poll.
package struct NextflowEngineLaunch: Sendable, Equatable {
    package var executable: URL
    package var arguments: [String]
    /// The whole environment, merged over the app's own by ``ProcessManager``.
    package var environment: [String: String]
    package var logFile: URL
    /// The first part of the log, such as TaxTriage's launch metadata.
    package var logPreamble: String
    /// The file `-with-trace` names, polled for progress when the hooks report it, else nil.
    package var traceFile: URL?

    package init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        logFile: URL,
        logPreamble: String,
        traceFile: URL?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.logFile = logFile
        self.logPreamble = logPreamble
        self.traceFile = traceFile
    }
}

/// A run's scratch, the launch folder with `.nextflow/` and the `-w` work folder, with no removal
/// root when it is kept for debugging (N7).
package struct NextflowEngineScratch: Sendable, Equatable {
    package let launchDirectory: URL
    package let workDirectory: URL
    package let removalRoot: URL?

    package init(launchDirectory: URL, workDirectory: URL, removalRoot: URL?) {
        self.launchDirectory = launchDirectory
        self.workDirectory = workDirectory
        self.removalRoot = removalRoot
    }
}

/// What happens to a scratch once the caller's record is written (N5, N7).
package enum NextflowScratchDisposition: Sendable, Equatable {
    /// Removed now, which every run does except a cancelled CLI run.
    case remove
    /// Left for the abandoned-scratch sweep, which a cancelled executor unit of the CLI does.
    case leaveForSweep
}

/// How the engine ended once its tree is gone, with bounded tails and the log synchronized. A cancel
/// is read from the task, never from this.
package struct NextflowEngineOutcome: Sendable, Equatable {
    /// The exit status, the number of the signal that ended the engine, or -1 when none was reported.
    package let exitCode: Int32
    package let stdoutTail: [String]
    package let stderrTail: [String]
    package let logFile: URL
    /// Why `nextflow.log` is incomplete or unsynchronized, the first failed write, read-back or `fsync`,
    /// or nil when every byte reached the log and the sync succeeded (N8). The caller fails a run that
    /// ended on its own when this is set, and a cancel still wins (2.7 E5).
    package let logFailure: String?

    package init(exitCode: Int32, stdoutTail: [String], stderrTail: [String], logFile: URL, logFailure: String? = nil) {
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.logFile = logFile
        self.logFailure = logFailure
    }
}

/// Why an engine could not start or wait.
package enum NextflowEngineError: Error, LocalizedError, Equatable, Sendable {
    /// The Docker daemon did not answer within the wait.
    case dockerUnavailable
    /// `open -g -a Docker` failed, so the wait ended at once (N9). The detail is for the log.
    case dockerDesktopNotStarted(detail: String)
    /// The log could not be created, so nothing was launched.
    case logNotWritable(path: String, reason: String)

    /// The words TaxTriage has given since before 2.9 when Docker does not answer, which a failed
    /// `open` gives too (UX, N9).
    package static let dockerUnavailableReason =
        "Docker Desktop is not running or daemon is unreachable. Start Docker Desktop and retry."

    package var errorDescription: String? {
        switch self {
        case .dockerUnavailable, .dockerDesktopNotStarted:
            return Self.dockerUnavailableReason
        case .logNotWritable(let path, let reason):
            return "LGE could not write the Nextflow log \(path). \(reason)"
        }
    }
}
