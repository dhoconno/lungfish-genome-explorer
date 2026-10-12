// NextflowProgressReader.swift - Reads a Nextflow engine's progress from its stdout lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Reads a run's progress from the engine's stdout lines and reports it in the engine's share of the
/// bar, 0.10 to 0.90, with the line that moved it (W1).
///
/// The rule is TaxTriage's since before 2.9, moved here unchanged. A `process >` line counts its task
/// once it reads `[100%]` or cached, and the bar follows the completed count against an estimate of
/// the run's tasks, at most 0.95 of the share, which leaves room for the finish. The estimate is 15
/// tasks unless the workflow states how many tasks one sample runs (W2). Trace readings do not move
/// the bar yet.
package final class NextflowProgressReader: NextflowProgressReporting {
    private let tracker: CompletedProcessTracker
    private let report: @Sendable (Double, String) -> Void

    /// - Parameters:
    ///   - expectedTasksPerSample: How many tasks one sample runs, or nil for the estimate of 15 tasks.
    ///   - sampleCount: How many samples the launch runs.
    ///   - report: Receives each fraction of the whole bar with the trimmed line that moved it.
    package init(
        expectedTasksPerSample: Int?,
        sampleCount: Int,
        report: @escaping @Sendable (Double, String) -> Void
    ) {
        tracker = CompletedProcessTracker(
            estimatedTotalProcesses: expectedTasksPerSample.map { $0 * max(1, sampleCount) }
        )
        self.report = report
    }

    package func engineLine(_ line: String) {
        if let progressFraction = parseNextflowProcessLine(line, tracker: tracker) {
            report(0.10 + progressFraction * 0.80, line.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Trace readings do not move the bar yet (W2).
    package func traceProgress(_ progress: NextflowTraceProgress) {}

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
    private func parseNextflowProcessLine(
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
    private func extractProcessName(from line: String) -> String {
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
/// clamped below 1.0 to leave room for finalization. A workflow that states
/// its task count replaces the estimate.
final class CompletedProcessTracker: Sendable {
    private let completedCount = Mutex(0)

    /// Typical number of processes in a TaxTriage run (used for progress estimation).
    private let estimatedTotalProcesses: Int

    /// - Parameter estimatedTotalProcesses: The run's task count, or nil for the typical 15.
    init(estimatedTotalProcesses: Int? = nil) {
        self.estimatedTotalProcesses = max(1, estimatedTotalProcesses ?? 15)
    }

    /// Records a progress update and returns the estimated fraction complete (0.0 -- 1.0).
    func recordUpdate(_ update: WorkflowProgressUpdate) -> Double {
        let count = completedCount.withLock { count in
            if update.status == .completed || update.status == .cached {
                count += 1
            }
            return count
        }
        return min(Double(count) / Double(estimatedTotalProcesses), 0.95)
    }
}
