// NextflowProgressReader.swift - Reads a Nextflow engine's progress from its task lines and its trace file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Reads a run's progress and reports it in the engine's share of the bar, 0.10 to 0.90, with the
/// task the engine started last (W1, W2).
///
/// A task line is the line Nextflow prints when it submits a task, with `NXF_ANSI_LOG=false` as every
/// launch sets it. Nextflow 26.04 prints `[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP`
/// and Nextflow 25.04 printed `[9d/b2ebdf] Submitted process > ` before the same process path, each
/// followed by ` (<tag>)` when the task has a tag. The reader reports a task line as
/// `Running <process> (<tag>)`, or `Running <process>` for a task with no tag, where `<process>` is the
/// last part of the process path, such as `Running KRAKEN2_KRAKEN2 (SRR12486989)`. The raw line stays
/// in `nextflow.log`, which the engine writes before it hands the line over.
///
/// Neither form prints a line when a task ends, so a task line reports the bar where it already is.
/// The bar follows the completed rows of `trace.txt`, which the engine reads every 5 s and once more
/// when the engine has ended, against the tasks the run is expected to run. That is the workflow's
/// count for one sample times the samples, or an estimate of 15 tasks for the whole run when the
/// workflow states no count. A reading that moves the bar reports it with the words of the last task
/// line. A reading moves nothing until the engine has submitted a task, so a trace file that an
/// earlier run left in the output folder never moves the bar. The bar never moves back, and the
/// completed rows fill at most 0.95 of the share, which holds the bar at or below 0.86 and so below the
/// finish's 0.90 until the engine has ended, however many rows the trace holds.
package final class NextflowProgressReader: NextflowProgressReporting {
    /// The bar where the engine's share starts, which a task line reports before any task has ended.
    static let shareStart = 0.10
    /// The width of the engine's share of the bar.
    static let shareWidth = 0.80
    /// The part of the share that completed tasks may fill, which leaves room for the finish.
    static let completedShareLimit = 0.95
    /// The tasks a run is expected to run when its workflow states no count for one sample.
    static let estimatedTaskCount = 15

    private struct State {
        /// The bar last reported.
        var fraction: Double
        /// The words of the last task line, nil until the engine submits a task.
        var task: String?
    }

    private let expectedTasks: Int
    private let state = Mutex(State(fraction: NextflowProgressReader.shareStart, task: nil))
    private let report: @Sendable (Double, String) -> Void

    /// - Parameters:
    ///   - expectedTasksPerSample: How many tasks one sample runs, or nil for an estimate of 15 tasks
    ///     for the whole run.
    ///   - sampleCount: How many samples the launch runs.
    ///   - report: Receives each fraction of the whole bar with the words of the task line it shows. It
    ///     is called with the reader's lock held, so the bar it receives never moves back. It must
    ///     return promptly and must not call the reader.
    package init(
        expectedTasksPerSample: Int?,
        sampleCount: Int,
        report: @escaping @Sendable (Double, String) -> Void
    ) {
        expectedTasks = max(1, expectedTasksPerSample.map { $0 * max(1, sampleCount) } ?? Self.estimatedTaskCount)
        self.report = report
    }

    /// Reports a task line in its words at the bar the trace has reached. Any other line reports nothing.
    package func engineLine(_ line: String) {
        guard let words = Self.taskWords(in: line) else { return }
        state.withLock { state in
            state.task = words
            // Under the lock, so a reading from the trace poll never reports between the two and the
            // bar the receiver sees never moves back.
            report(state.fraction, words)
        }
    }

    /// Reports a reading that moves the bar on, with the words of the last task line. A reading
    /// before the first task line, or one that leaves the bar where it is, reports nothing.
    package func traceProgress(_ progress: NextflowTraceProgress) {
        state.withLock { state in
            guard let task = state.task else { return }
            let fraction = bar(completedTasks: progress.completedTasks)
            guard fraction > state.fraction else { return }
            state.fraction = fraction
            report(fraction, task)
        }
    }

    /// The bar for `completedTasks` completed tasks of the expected ones.
    private func bar(completedTasks: Int) -> Double {
        let filled = min(Double(max(0, completedTasks)) / Double(expectedTasks), Self.completedShareLimit)
        return Self.shareStart + filled * Self.shareWidth
    }

    // MARK: - Task lines

    /// The words of a task line, `Running <process> (<tag>)` or `Running <process>`, or nil when `line`
    /// is no task line.
    static func taskWords(in line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let task: Substring
        if text.hasPrefix("[PROCESS "), let close = text.firstIndex(of: "]") {
            task = text[text.index(after: close)...]
        } else if text.hasPrefix("["), let marker = text.range(of: "] Submitted process > ") {
            task = text[marker.upperBound...]
        } else {
            return nil
        }
        let description = task.trimmingCharacters(in: .whitespaces)
        let path = description.prefix { $0 != " " }
        guard let process = path.split(separator: ":").last else { return nil }
        let rest = description.dropFirst(path.count).trimmingCharacters(in: .whitespaces)
        guard rest.count > 2, rest.hasPrefix("("), rest.hasSuffix(")") else {
            return "Running \(process)"
        }
        return "Running \(process) \(rest)"
    }
}
