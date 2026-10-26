// CondaToolTimeLimit.swift - The wall-clock limit of a conda tool run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What the conda family of runners says about the wall-clock limit of a tool run.
///
/// An analysis tool has no wall-clock limit by default, and a limit is a named option that the caller
/// sets (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time).
enum CondaToolTimeLimit {
    /// Receives the spec of each `CondaManager.runTool` launch built in the current task, just before the launch.
    ///
    /// Production never binds it. A test binds it around one call to read the limit that call built, so no test
    /// has to run a tool for the length of a limit. It follows the task like `ToolProcessObservation.observer`,
    /// so it holds no state and one test cannot read the launches of another.
    @TaskLocal static var specProbe: (@Sendable (ToolProcessSpec) -> Void)?

    /// The words of a stop by a time limit. They say what was stopped, after how long, that a time limit did it
    /// and what to try next. `subject` names what the limit stopped, such as `Tool 'kraken2'`.
    static func stoppedWords(_ subject: String, seconds: TimeInterval) -> String {
        let tryNext = "Run it again with no time limit or a longer one."
        guard let duration = readable(seconds: seconds) else {
            return "\(subject) was stopped by its time limit. \(tryNext)"
        }
        return "\(subject) was stopped after \(duration) by its time limit. \(tryNext)"
    }

    /// A limit as a person reads it, in seconds under two minutes, in minutes under two hours and in whole hours
    /// from two hours up. Nil for a value that is not finite, which is no limit at all.
    static func readable(seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds < 9e9 else { return nil }
        let whole = max(1, Int(seconds.rounded()))
        if whole < 120 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        if whole >= 7_200, whole % 3_600 == 0 { return "\(whole / 3_600) hours" }
        return "\(Int((seconds / 60).rounded())) minutes"
    }
}
