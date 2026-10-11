// AnalysisRunEvents.swift - The event sink of an analysis run, which delivers each event line whole under one lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Where an analysis run's events go, and the stream the executor writes to it.
///
/// The stream, in this order.
///
/// 1. One `start` line.
/// 2. One `output` line with the role `CLIEventArtifact.Role.analysisDirectory` and the result
///    folder's absolute path, written once the folder exists (phase P1) and before any unit runs.
///    A run that ends in its plan writes none.
/// 3. `progress` lines, whose fraction stays from 0 to 1 as `(index + fraction) / count` for unit
///    `index` of `count`, and `log` lines. Each `log` line at level `warning` is one of the run's
///    warnings, and a completed run with a warning reads Completed with Warnings.
/// 4. Exactly one last line. `complete` names the result folder in `outputs`, carries the
///    finalization's artifacts and the root record with the role `provenance`, and has the
///    completion detail as its message. `failed` has the report's message. A cancelled run ends
///    with `failed` and exit 125.
///
/// Tools emit from `ToolProcess` queues while the executor emits from its own task, so every
/// delivery runs under one lock. A line is handed on whole and in the order the lock was taken,
/// and the next line waits until the delivery returns, so a delivery that writes and flushes
/// never interleaves with another. The lock is not recursive, so a delivery must never emit on the
/// sink that called it.
public struct AnalysisRunEvents: Sendable {
    private let channel: Channel

    /// A sink that hands each line to `deliver`, one at a time.
    public init(_ deliver: @escaping @Sendable (CLIEventLine) -> Void) {
        channel = Channel(deliver: deliver)
    }

    /// A sink that writes each line as one version 2 JSON object with sorted keys, the form
    /// `--format json` prints. `writeLine` gets one whole line, without a newline, and should
    /// write and flush it before it returns.
    public static func jsonLines(_ writeLine: @escaping @Sendable (String) -> Void) -> AnalysisRunEvents {
        AnalysisRunEvents { line in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(line), let text = String(data: data, encoding: .utf8) else {
                return
            }
            writeLine(text)
        }
    }

    /// A sink that drops every event.
    public static var discarding: AnalysisRunEvents {
        AnalysisRunEvents { _ in }
    }

    /// Delivers one event. Artifacts ride only on `complete` and `output` lines.
    public func emit(_ event: CLIEvent, artifacts: [CLIEventArtifact] = []) {
        channel.deliver(CLIEventLine(event: event, artifacts: artifacts))
    }

    private final class Channel: Sendable {
        private let lock = Mutex(())
        private let deliverLine: @Sendable (CLIEventLine) -> Void

        init(deliver: @escaping @Sendable (CLIEventLine) -> Void) {
            deliverLine = deliver
        }

        func deliver(_ line: CLIEventLine) {
            lock.withLock { _ in
                deliverLine(line)
            }
        }
    }
}

extension CLIEventArtifact.Role {
    /// The result folder of an analysis run, named by the early `output` line of its stream.
    public static let analysisDirectory = "analysis-directory"
}
