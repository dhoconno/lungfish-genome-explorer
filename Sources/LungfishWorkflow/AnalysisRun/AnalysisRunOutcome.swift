// AnalysisRunOutcome.swift - How a unit ends, and the terminal policy that turns unit outcomes into the run's end
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How one unit ended.
public enum AnalysisUnitOutcome<Result: Sendable>: Sendable {
    /// The unit wrote its result.
    case completed(Result)
    /// The unit wrote a result that holds less than asked, such as a Kraken2 sample whose Bracken
    /// profile degraded (E4). The run still completes, with exit 0 and status `completed`, and
    /// `reason` becomes a warning line.
    case completedWithWarning(Result, reason: String)
    /// The unit wrote no result. The tool's ``AnalysisRunTerminalPolicy`` says what that does to
    /// the run.
    case failed(reason: String)

    /// The result of a unit that completed, with or without a warning.
    public var result: Result? {
        switch self {
        case .completed(let result), .completedWithWarning(let result, _):
            return result
        case .failed:
            return nil
        }
    }

    /// Whether the unit wrote a result.
    public var completed: Bool {
        result != nil
    }
}

/// One unit that ran, as ``AnalysisRunTool/finalize(_:context:)`` and the terminal policy see it.
public struct AnalysisUnitReport<Result: Sendable>: Sendable {
    /// The unit's place in the plan, from 0.
    public let index: Int
    public let label: String
    /// The name the unit gave its sample, the unit folder's name in a batch root.
    public let sampleName: String
    public let directory: URL
    public let outcome: AnalysisUnitOutcome<Result>

    public init(
        index: Int,
        label: String,
        sampleName: String,
        directory: URL,
        outcome: AnalysisUnitOutcome<Result>
    ) {
        self.index = index
        self.label = label
        self.sampleName = sampleName
        self.directory = directory
        self.outcome = outcome
    }
}

/// How a run that was not cancelled ends after its units.
public enum AnalysisRunTerminalOutcome: Sendable, Equatable {
    /// The run completed. Its warnings are the warning lines it wrote.
    case completed
    /// The run failed, for `reason`.
    case failed(reason: String)
}

/// The rule a tool supplies for how its unit outcomes end the run (E4).
///
/// A unit that completes with a warning always leaves the run completed, with exit 0 and a warning
/// line that names the reason. The policy decides what a failed unit does.
public struct AnalysisRunTerminalPolicy: Sendable, Equatable {
    /// What a failed unit does to the run.
    public enum FailedUnits: String, Sendable, Equatable, CaseIterable {
        /// The first failed unit fails the run, and no later unit runs.
        case failRun
        /// Every unit runs. A failed unit is a warning, and the run fails only when no unit
        /// completed, as the app's classifier batches end today (Completed with Warnings).
        case warnWhileAnotherUnitCompletes
    }

    public var failedUnits: FailedUnits

    public init(failedUnits: FailedUnits) {
        self.failedUnits = failedUnits
    }

    /// Any failed unit fails the run. The default.
    public static let failOnAnyFailedUnit = AnalysisRunTerminalPolicy(failedUnits: .failRun)

    /// Failed units are warnings while another unit completes.
    public static let warnOnFailedUnits = AnalysisRunTerminalPolicy(failedUnits: .warnWhileAnotherUnitCompletes)

    /// Whether the executor runs the next unit after `report`.
    public func continues<Result>(after report: AnalysisUnitReport<Result>) -> Bool {
        report.outcome.completed || failedUnits == .warnWhileAnotherUnitCompletes
    }

    /// The warning line a unit's outcome adds to the run, or nil. In a plan of several units the
    /// line names the unit.
    public func warning<Result>(for report: AnalysisUnitReport<Result>, unitCount: Int) -> String? {
        switch report.outcome {
        case .completed:
            return nil
        case .completedWithWarning(_, let reason):
            return unitCount > 1 ? "\(report.label): \(reason)" : reason
        case .failed(let reason):
            // A failed unit that fails the run is said once, by the run's failure.
            guard failedUnits == .warnWhileAnotherUnitCompletes, unitCount > 1 else { return nil }
            return Self.failureLine(label: report.label, reason: reason)
        }
    }

    /// How the units that ran end the run.
    public func outcome<Result>(for reports: [AnalysisUnitReport<Result>], unitCount: Int) -> AnalysisRunTerminalOutcome {
        switch failedUnits {
        case .failRun:
            guard let failed = reports.first(where: { !$0.outcome.completed }),
                  case .failed(let reason) = failed.outcome else {
                return reports.isEmpty ? .failed(reason: "No unit ran.") : .completed
            }
            return .failed(reason: unitCount > 1 ? Self.failureLine(label: failed.label, reason: reason) : reason)
        case .warnWhileAnotherUnitCompletes:
            if reports.contains(where: { $0.outcome.completed }) {
                return .completed
            }
            if unitCount == 1, case .failed(let reason)? = reports.first?.outcome {
                return .failed(reason: reason)
            }
            return .failed(reason: "None of the \(unitCount) runs completed.")
        }
    }

    private static func failureLine(label: String, reason: String) -> String {
        "\(label) failed: \(reason)"
    }
}
