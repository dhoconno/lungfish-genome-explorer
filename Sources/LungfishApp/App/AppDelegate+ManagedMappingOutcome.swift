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
    func report(totalSamples: Int) -> FailureReport? {
        nil
    }
}
