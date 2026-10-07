// TwelveSAmpliconMatchingWorkflow+EarlierResult.swift - Says where an earlier 12S result waits when it cannot be moved back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A forced 12S run failed after it set the earlier result aside, and the
/// earlier result could not be moved back either. The description is the
/// reason the run failed, then one line that says where the earlier result
/// waits, as `fastq demultiplex` says it of its earlier output. `lungfish-cli`
/// prints it as its error, and the app shows it with the CLI's error output
/// (Phase 2.1 re-review 2, N6).
public struct TwelveSEarlierResultNotRestoredError: Error, LocalizedError, Equatable {
    /// The description of the error that stopped the run.
    public let failure: String
    /// Where the earlier result was, and where the failed run wrote its bundle.
    public let bundleURL: URL
    /// Where the earlier result waits.
    public let asideURL: URL

    public init(failure: String, bundleURL: URL, asideURL: URL) {
        self.failure = failure
        self.bundleURL = bundleURL
        self.asideURL = asideURL
    }

    public var errorDescription: String? {
        "\(failure)\nThe earlier 12S result could not be moved back to \(bundleURL.lastPathComponent), and it waits at \(asideURL.path)."
    }
}

extension TwelveSAmpliconMatchingWorkflow {
    /// Moves the earlier result back after `failure` stopped the run. When it
    /// cannot be moved back, the error thrown says where it waits.
    static func restoreEarlierResult(_ earlierOutput: SetAsideOutput?, after failure: any Error) throws {
        guard let earlierOutput else { return }
        do {
            try earlierOutput.restore()
        } catch {
            throw TwelveSEarlierResultNotRestoredError(
                failure: describe(failure),
                bundleURL: earlierOutput.outputURL,
                asideURL: earlierOutput.asideURL
            )
        }
    }

    /// The text ArgumentParser prints for `error`, so the reason the run
    /// failed reads as it would have read on its own.
    private static func describe(_ error: any Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        return type(of: error) is NSError.Type ? error.localizedDescription : String(describing: error)
    }
}
