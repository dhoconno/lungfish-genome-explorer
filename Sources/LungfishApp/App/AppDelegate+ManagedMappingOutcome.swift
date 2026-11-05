// AppDelegate+ManagedMappingOutcome.swift - How one Map Reads run ended, and the alert a batch shows for its failures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// How one `lungfish-cli map` run through `runSingleManagedMappingThroughCLI` ended (UWORDS, Phase 3.2).
///
/// A Bool could not tell a cancel from a failure, and only a failure shows an alert.
enum ManagedMappingOutcome: Sendable, Equatable {
    /// The result stands, even when a cancel came after the command finished.
    case succeeded
    /// The person cancelled, or the row would not start. The row says so and nothing more is shown.
    case stopped
    /// The run failed. The words are the failed line's, the same words the row shows.
    case failed(String)
}

/// The failures of one Map Reads batch, in the order the samples ran, and the one alert they share (UWORDS).
struct MappingBatchFailures: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let sample: String
        let words: String
    }

    private(set) var entries: [Entry] = []

    /// Keeps a failed run and ignores a run that succeeded or stopped.
    mutating func record(_ outcome: ManagedMappingOutcome, sample: String) {
        guard case .failed(let words) = outcome else { return }
        entries.append(Entry(sample: sample, words: words))
    }

    /// The one alert for the batch, or nil when no sample failed. `totalSamples` is the batch's size.
    ///
    /// One failed sample gets the failed line's first line as the words. Several get their names, the first five and a
    /// count of the rest, and Show Details lists every failed sample with its reason (UWORDS UX should-fix 1). The
    /// Operations panel holds each sample's log. A single sample's reason of several lines goes behind Show Details.
    func report(totalSamples: Int) -> FailureReport? {
        guard let first = entries.first else { return nil }
        if entries.count == 1 {
            let lines = first.words.split(whereSeparator: \.isNewline).map(String.init)
            return FailureReport(
                failedStep: "Run Map Reads for \(first.sample)",
                whatHappened: Self.sentence(lines.first ?? ""),
                nextStep: "Check the reads and the reference, then run it again. The Operations panel holds the log.",
                underlying: lines.count > 1 ? MappingRunFailureWords(words: first.words) : nil
            )
        }
        let names = entries.prefix(5).map(\.sample).joined(separator: ", ")
        let rest = entries.count > 5 ? " and \(entries.count - 5) more" : ""
        return FailureReport(
            failedStep: "Run Map Reads for \(entries.count) of \(totalSamples) samples",
            whatHappened: "Map Reads failed for \(names)\(rest).",
            nextStep: "Check the reads and the reference of those samples, then run them again. Show Details gives each sample's reason, and the Operations panel holds each sample's log.",
            itemErrors: entries.map { (name: $0.sample, error: MappingRunFailureWords(words: $0.words) as any Error) }
        )
    }

    /// The words as a sentence, with the full stop the failed line may lack.
    private static func sentence(_ words: String) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Map Reads stopped, and the run gave no reason." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

/// A failed run's words as an error, so that a reason of several lines can sit in the alert's details area.
///
/// The type is private to this file, and a private Swift type bridges to a domain such as
/// "LungfishApp.(unknown context at $105401cd8).MappingRunFailureWords", which Show Details printed (W-31). So the
/// error names its own domain, "Mapping".
private struct MappingRunFailureWords: LocalizedError, CustomNSError {
    let words: String
    var errorDescription: String? { words }
    static var errorDomain: String { "Mapping" }
}
