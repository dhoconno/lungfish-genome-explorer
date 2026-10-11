// AnalysisRunExecutor+Units.swift - The unit loop of an analysis run, phase P2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The units that ran, and whether a cancel request stopped the loop.
struct AnalysisRunUnitResults<Result: Sendable>: Sendable {
    var reports: [AnalysisUnitReport<Result>]
    var cancelled: Bool
}

extension AnalysisRunExecutor {
    /// Runs the plan's units one at a time, in plan order.
    ///
    /// A `batchRoot` layout gives each unit its own folder through
    /// `AnalysesFolder.batchSampleDirectory`, the one sanitizer, and the unit's sample name is that
    /// folder's name. The other layouts hand each unit the result folder itself. The loop checks for a
    /// cancel request, the task's cancellation or the services' `cancelRequested`, before each
    /// unit and after it, whatever the unit returned or threw. A cancel request, and nothing else,
    /// makes the run cancelled, so a unit that failed because its child process was signalled
    /// during a cancel still reads cancelled, also when it failed before the task was cancelled,
    /// and one that failed the same way without a cancel request reads failed (SWIFT X2). The
    /// tool's policy says whether the loop goes on after a failed unit.
    func runUnits<Tool: AnalysisRunTool>(
        _ tool: Tool,
        plan: AnalysisRunPlan<Tool.Unit>,
        folder: AnalysisRunFolder,
        journal: AnalysisRunJournal
    ) async -> AnalysisRunUnitResults<Tool.UnitResult> {
        let count = plan.units.count
        let policy = tool.terminalPolicy
        var reports: [AnalysisUnitReport<Tool.UnitResult>] = []
        for (index, planned) in plan.units.enumerated() {
            guard !cancelIsRequested else {
                return AnalysisRunUnitResults(reports: reports, cancelled: true)
            }
            journal.emit(.progress(
                fraction: AnalysisRunJournal.runFraction(index: index, count: count, unitFraction: 0),
                message: count > 1 ? "Running \(planned.label) (\(index + 1) of \(count))." : "Running \(planned.label)."
            ))

            var directory = folder.root
            var sampleName = planned.label
            let outcome: AnalysisUnitOutcome<Tool.UnitResult>
            do {
                switch plan.layout {
                case .batchRoot:
                    directory = try AnalysesFolder.batchSampleDirectory(named: planned.label, in: folder.root)
                    sampleName = directory.lastPathComponent
                case .singleFolder, .sharedBatchRoot:
                    break
                }
                outcome = try await tool.run(
                    AnalysisRunUnit(
                        index: index,
                        count: count,
                        label: planned.label,
                        sampleName: sampleName,
                        directory: directory,
                        value: planned.value
                    ),
                    context: journal.unitContext(
                        index: index,
                        count: count,
                        rootDirectory: folder.root,
                        projectURL: folder.projectURL
                    )
                )
            } catch {
                outcome = .failed(reason: Self.reason(for: error))
            }
            // What the unit recorded before the cancel stays in the root record. Its outcome,
            // whatever ended its child process, does not decide the status.
            guard !cancelIsRequested else {
                return AnalysisRunUnitResults(reports: reports, cancelled: true)
            }

            let report = AnalysisUnitReport(
                index: index,
                label: planned.label,
                sampleName: sampleName,
                directory: directory,
                outcome: outcome
            )
            reports.append(report)
            if let warning = policy.warning(for: report, unitCount: count) {
                journal.warn(warning)
            }
            guard policy.continues(after: report) else { break }
        }
        return AnalysisRunUnitResults(reports: reports, cancelled: false)
    }
}
