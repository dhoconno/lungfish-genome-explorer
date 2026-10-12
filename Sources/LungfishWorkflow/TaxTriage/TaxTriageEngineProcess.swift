// TaxTriageEngineProcess.swift - The launch scratch and the output lines of TaxTriage's Nextflow engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "TaxTriagePipeline")

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
