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
    /// Nextflow's grace on the in-process route, which fits inside the 6 s the app's transport
    /// gives the CLI (T12).
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
        let handle = try await processManager.spawn(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            drainGracePeriod: nil,
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
        let processManager = processManager
        return await withTaskCancellationHandler {
            await streaming.value
        } onCancel: {
            // Runs at once when the task was cancelled during the launch, so no cancel is lost.
            Task { await processManager.terminate(id: handle.id) }
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

// MARK: - Engine launch

extension TaxTriagePipeline {
    // MARK: - Local launch scratch

    /// A local, lock-capable scratch area used as the Nextflow launch
    /// directory (host of `.nextflow/` cache + history) and work tree.
    struct LaunchScratch: Sendable {
        /// Process working directory for the Nextflow launcher.
        let launchDirectory: URL
        /// Value passed to `nextflow -w`.
        let workDirectory: URL
        /// Root to delete once the run finishes; `nil` when kept for debugging.
        let cleanupRoot: URL?
    }

    /// Set to `1` to keep the Nextflow launch scratch (including `work/`) after a run.
    static let keepWorkEnvironmentKey = "LUNGFISH_TAXTRIAGE_KEEP_WORK"

    nonisolated func makeLocalLaunchScratch(
        contextURL: URL,
        volumeQualifiesForScratch: Bool? = nil
    ) throws -> LaunchScratch {
        // The scratch stays on the PROJECT volume whenever it can host
        // Nextflow's cache: external project SSDs are usually far larger
        // than the boot volume, so multi-GB work trees belong there. Only a
        // disqualified volume (no fcntl locks, or AppleDouble xattr sidecars
        // that crash the LevelDB cache — exFAT via FSKit, some network
        // mounts) forces local storage. See NextflowScratchVolumeProbe.
        let scratchCapable = volumeQualifiesForScratch
            ?? NextflowScratchVolumeProbe.volumeSupportsNextflowScratch(at: contextURL)
        let root = try ProjectTempDirectory.create(
            prefix: "taxtriage-run-",
            contextURL: contextURL,
            policy: scratchCapable ? .preferProjectContext : .systemOnly
        )
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let keepWork = ProcessInfo.processInfo.environment[Self.keepWorkEnvironmentKey] == "1"
        if keepWork {
            logger.info("Keeping TaxTriage launch scratch at \(root.path, privacy: .public)")
        }
        return LaunchScratch(
            launchDirectory: root,
            workDirectory: workDirectory,
            cleanupRoot: keepWork ? nil : root
        )
    }

    nonisolated func cleanUpLaunchScratch(_ scratch: LaunchScratch) {
        guard let cleanupRoot = scratch.cleanupRoot else { return }
        do {
            try FileManager.default.removeItem(at: cleanupRoot)
        } catch {
            logger.warning(
                "Failed to clean TaxTriage launch scratch \(cleanupRoot.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Progress Parsing

    /// Parses a Nextflow stdout line for process completion.
    ///
    /// Nextflow outputs lines like:
    /// ```
    /// [ab/cd1234] process > PROCESS_NAME (1) [100%] 1 of 1
    /// ```
    ///
    /// - Parameters:
    ///   - line: A single stdout line.
    ///   - tracker: The process completion tracker.
    /// - Returns: The updated overall progress fraction, or nil if not a process line.
    nonisolated func parseNextflowProcessLine(
        _ line: String,
        tracker: CompletedProcessTracker
    ) -> Double? {
        guard line.contains("process >") else { return nil }

        var status = WorkflowProgressUpdate.ProcessStatus.running
        if line.contains("[100%]") {
            status = .completed
        } else if line.lowercased().contains("cached") {
            status = .cached
        }

        let update = WorkflowProgressUpdate(
            process: extractProcessName(from: line),
            status: status,
            message: line
        )
        return tracker.recordUpdate(update)
    }

    /// Extracts the process name from a Nextflow progress line.
    private nonisolated func extractProcessName(from line: String) -> String {
        // Look for pattern: "process > PROCESS_NAME"
        guard let rangeOfMarker = line.range(of: "process >") else {
            return "unknown"
        }
        let afterMarker = line[rangeOfMarker.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        // Take up to the first space or parenthesis
        let name = afterMarker.prefix {
            $0 != " " && $0 != "(" && $0 != "["
        }
        return name.isEmpty ? "unknown" : String(name)
    }
}

// MARK: - CompletedProcessTracker

/// Tracks completed Nextflow processes to estimate overall progress.
///
/// Since we do not know the total number of processes in advance, the tracker
/// uses a linear estimate based on a typical TaxTriage process count,
/// clamped below 1.0 to leave room for finalization.
final class CompletedProcessTracker: @unchecked Sendable {
    private var completedCount = 0
    private let lock = NSLock()

    /// Typical number of processes in a TaxTriage run (used for progress estimation).
    private let estimatedTotalProcesses = 15

    /// Records a progress update and returns the estimated fraction complete (0.0 -- 1.0).
    func recordUpdate(_ update: WorkflowProgressUpdate) -> Double {
        if update.status == .completed || update.status == .cached {
            lock.lock()
            completedCount += 1
            let count = completedCount
            lock.unlock()

            return min(Double(count) / Double(estimatedTotalProcesses), 0.95)
        }

        lock.lock()
        let count = completedCount
        lock.unlock()
        return min(Double(count) / Double(estimatedTotalProcesses), 0.95)
    }
}
