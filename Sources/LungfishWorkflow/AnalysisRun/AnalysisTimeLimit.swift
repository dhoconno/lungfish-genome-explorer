// AnalysisTimeLimit.swift - The wall-clock limit a person sets on one analysis run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The wall-clock limit a person sets with `--time-limit <minutes>`. Each analysis launch of the run gets the whole
/// limit, so a run of several launches can last longer than the limit.
///
/// An analysis tool has no wall-clock limit by default, and a limit is a named option that the run records
/// (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time). A command that offers the option runs its body inside
/// ``withLimit(_:_:)``, and every analysis launch of that run reads ``launchTimeout`` where it builds its launch.
/// With no limit set the value is `.infinity`, which `CondaManager.runTool`, `NativeToolRunner` and the
/// conda-family launchers all read as no limit.
///
/// The limit follows the task, as `ToolProcessObservation.observer` does. A pipeline and its helpers need no extra
/// parameter, and a copy of a request cannot drop it. A task started with `Task.detached` does not inherit the
/// limit, and no analysis pipeline starts one.
public struct AnalysisTimeLimit: Sendable, Hashable {
    /// The option that sets the limit, in the words of the commands that offer it.
    public static let optionName = "--time-limit"

    /// The key under which a run records the limit when it was set, in whole minutes.
    public static let recordKey = "timeLimitMinutes"

    /// The longest limit the option takes, one year. A longer value is not a limit a person means.
    public static let maximumMinutes = 525_600

    /// The limit in whole minutes, from 1 to ``maximumMinutes``.
    public let minutes: Int

    /// Nil for a value that is not a whole number of minutes from 1 to ``maximumMinutes``.
    public init?(minutes: Int) {
        guard (1...Self.maximumMinutes).contains(minutes) else { return nil }
        self.minutes = minutes
    }

    /// The limit in seconds, the unit of a `timeout:` argument.
    public var seconds: TimeInterval { TimeInterval(minutes) * 60 }

    /// The limit of the run the current task belongs to, nil when the person set none.
    @TaskLocal public static var current: AnalysisTimeLimit?

    /// The `timeout:` of an analysis launch in the current task, in seconds. `.infinity` means no limit.
    public static var launchTimeout: TimeInterval { current?.seconds ?? .infinity }

    /// `parameters` with the limit of the current run under ``recordKey`` when a person set one. A command that
    /// offers the option builds the parameters of its run record through this, so the record holds the limit
    /// the launches of the run carried and nothing when there was none.
    public static func recording(_ parameters: [String: ParameterValue]) -> [String: ParameterValue] {
        guard let limit = current else { return parameters }
        var recorded = parameters
        recorded[recordKey] = .integer(limit.minutes)
        return recorded
    }

    /// Runs `body` as one run under `limit`. A nil limit runs it with no limit, and so does a run no command scoped.
    public static func withLimit<Result>(
        _ limit: AnalysisTimeLimit?,
        _ body: () async throws -> Result
    ) async rethrows -> Result {
        try await $current.withValue(limit, operation: body)
    }
}
