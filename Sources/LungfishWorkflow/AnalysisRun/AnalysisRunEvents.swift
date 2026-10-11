// AnalysisRunEvents.swift - The event sink of an analysis run, which delivers each event line whole under one lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Where an analysis run's events go.
///
/// Tools emit from `ToolProcess` queues while the executor emits from its own task, so every
/// delivery runs under one lock. A line is handed on whole and in the order the lock was taken,
/// and the next line waits until the delivery returns, so a delivery that writes and flushes
/// never interleaves with another.
public struct AnalysisRunEvents: Sendable {
    /// Roles of the lines an analysis run writes.
    public enum Role {
        /// The early `output` line that names the result folder, written once the folder exists.
        public static let analysisDirectory = "analysis-directory"
    }

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
