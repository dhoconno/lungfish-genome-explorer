// OperationStatsAggregator.swift - Summarizes operation runtime and memory provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct OperationStatsReport: Sendable, Equatable {
    public let projectURL: URL
    public let sidecarCount: Int
    public let completedRunCount: Int
    public let totalWallTimeSeconds: TimeInterval
    public let peakMemoryBytes: UInt64?
    public let operations: [OperationStatsSummary]
}

public struct OperationStatsSummary: Sendable, Equatable, Identifiable {
    public var id: String { name }

    public let name: String
    public let completedRunCount: Int
    public let totalWallTimeSeconds: TimeInterval
    public let averageWallTimeSeconds: TimeInterval
    public let peakMemoryBytes: UInt64?
}

/// Summarizes the completed runs recorded under a project for `lungfish-cli ops stats`.
///
/// It reads every file named exactly `.lungfish-provenance.json` through
/// `ProvenanceEnvelopeReader`, so a record of any schema version counts. A record counts as a
/// completed run when it decodes as an envelope or a bare `WorkflowRun` and states that its run
/// completed. An exit status of 0 alone is not enough, because a run cancelled in Bracken
/// preparation can end on a step that exited 0, and a record only the primitive adapter reads
/// states no status at all.
public struct OperationStatsAggregator: Sendable {
    public init() {}

    /// One completed run as `ops stats` counts it.
    private struct CompletedRun {
        let name: String
        let wallTimeSeconds: TimeInterval
        let peakMemoryBytes: UInt64?
    }

    /// The run's start and end that a version 1 record and a bare run hold as whole-second
    /// dates. Version 2 drops them, and the canonical fields give the same span.
    private struct RecordedRunDates: Decodable {
        let startTime: Date?
        let endTime: Date?

        private enum CodingKeys: String, CodingKey {
            case startTime
            case endTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startTime = try? container.decodeIfPresent(Date.self, forKey: .startTime)
            endTime = try? container.decodeIfPresent(Date.self, forKey: .endTime)
        }
    }

    public func summarize(projectURL: URL) throws -> OperationStatsReport {
        let sidecarURLs = try provenanceSidecars(under: projectURL)
        let completedRuns = sidecarURLs.compactMap(Self.completedRun(at:))

        var grouped: [String: [CompletedRun]] = [:]
        for run in completedRuns {
            grouped[run.name, default: []].append(run)
        }

        let operations: [OperationStatsSummary] = grouped.map { name, runs in
            let totalWallTime = runs.reduce(0) { partial, run in
                partial + run.wallTimeSeconds
            }
            return OperationStatsSummary(
                name: name,
                completedRunCount: runs.count,
                totalWallTimeSeconds: totalWallTime,
                averageWallTimeSeconds: runs.isEmpty ? 0 : totalWallTime / Double(runs.count),
                peakMemoryBytes: Self.peakMemoryBytes(for: runs)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let totalWallTime = completedRuns.reduce(0) { partial, run in
            partial + run.wallTimeSeconds
        }

        return OperationStatsReport(
            projectURL: projectURL,
            sidecarCount: sidecarURLs.count,
            completedRunCount: completedRuns.count,
            totalWallTimeSeconds: totalWallTime,
            peakMemoryBytes: Self.peakMemoryBytes(for: completedRuns),
            operations: operations
        )
    }

    private func provenanceSidecars(under projectURL: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: projectURL.path])
        }

        if !isDirectory.boolValue {
            return projectURL.lastPathComponent == ProvenanceRecorder.provenanceFilename ? [projectURL] : []
        }

        guard let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        var sidecars: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == ProvenanceRecorder.provenanceFilename {
            sidecars.append(url)
        }
        return sidecars.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func completedRun(at url: URL) -> CompletedRun? {
        guard let data = try? Data(contentsOf: url),
              let reading = try? ProvenanceEnvelopeReader.read(data),
              reading.shape != .primitive,
              reading.statusWasRecorded,
              reading.envelope.status == .completed else {
            return nil
        }
        let envelope = reading.envelope
        return CompletedRun(
            name: envelope.workflowName,
            wallTimeSeconds: wallTimeSeconds(of: envelope, recordedIn: data),
            peakMemoryBytes: envelope.steps.compactMap(\.peakMemoryBytes).max()
        )
    }

    /// The recorded start and end when the record holds both, the span the canonical fields give
    /// otherwise, and the sum of the step wall times when the run has no end.
    private static func wallTimeSeconds(of envelope: ProvenanceEnvelope, recordedIn data: Data) -> TimeInterval {
        if let recorded = try? ProvenanceJSON.decoder.decode(RecordedRunDates.self, from: data),
           let start = recorded.startTime,
           let end = recorded.endTime {
            return end.timeIntervalSince(start)
        }
        if let wallTime = envelope.legacyWorkflowRun().wallTime {
            return wallTime
        }
        return envelope.steps.reduce(0) { $0 + ($1.wallTimeSeconds ?? 0) }
    }

    private static func peakMemoryBytes(for runs: [CompletedRun]) -> UInt64? {
        runs.compactMap(\.peakMemoryBytes).max()
    }
}
