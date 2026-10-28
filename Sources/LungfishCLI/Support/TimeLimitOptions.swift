// TimeLimitOptions.swift - The --time-limit option of an analysis command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// The one named time-limit option of an analysis command (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time).
///
/// Without it the run has no wall-clock limit. A command adds `@OptionGroup var timeLimit: TimeLimitOptions`,
/// runs its body inside ``scope(_:)``, spells ``argumentWords`` in the command line it records, and records
/// ``AnalysisTimeLimit/recordKey`` in its options when ``limit`` is set.
struct TimeLimitOptions: ParsableArguments {
    @Option(
        name: .customLong("time-limit"),
        help: ArgumentHelp(
            "Stop the run after this many minutes. Without it the run has no time limit.",
            valueName: "minutes"
        )
    )
    var minutes: Int?

    /// The limit, nil when the option was not given.
    var limit: AnalysisTimeLimit? { minutes.flatMap { AnalysisTimeLimit(minutes: $0) } }

    /// The words that spell the option in a command line, empty when it was not given.
    var argumentWords: [String] { minutes.map { [AnalysisTimeLimit.optionName, String($0)] } ?? [] }

    mutating func validate() throws {
        guard let minutes, AnalysisTimeLimit(minutes: minutes) == nil else { return }
        throw ValidationError(
            "\(AnalysisTimeLimit.optionName) takes a whole number of minutes from 1 to \(AnalysisTimeLimit.maximumMinutes), "
                + "not \(minutes). Leave the option out to run with no time limit."
        )
    }

    /// Runs `body` as one run under the limit, or with no limit when the option was not given.
    func scope<Result>(_ body: () async throws -> Result) async rethrows -> Result {
        try await AnalysisTimeLimit.withLimit(limit, body)
    }

    /// The entry a run records for the limit, empty when it was not set.
    var recordEntries: [String: ParameterValue] {
        limit.map { [AnalysisTimeLimit.recordKey: .integer($0.minutes)] } ?? [:]
    }
}
