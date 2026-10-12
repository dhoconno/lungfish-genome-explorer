// NextflowProgressReader.swift - Reads a Nextflow engine's progress from its stdout lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriagePipeline {
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
