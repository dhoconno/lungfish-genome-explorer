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

public struct OperationStatsAggregator: Sendable {
    public init() {}

    public func summarize(projectURL: URL) throws -> OperationStatsReport {
        let sidecarURLs = try provenanceSidecars(under: projectURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let runs = sidecarURLs.compactMap { url -> WorkflowRun? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(WorkflowRun.self, from: data)
        }
        let completedRuns = runs.filter { $0.status == .completed }

        var grouped: [String: [WorkflowRun]] = [:]
        for run in completedRuns {
            grouped[run.name, default: []].append(run)
        }

        let operations: [OperationStatsSummary] = grouped.map { name, runs in
            let totalWallTime = runs.reduce(0) { partial, run in
                partial + Self.wallTimeSeconds(for: run)
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
            partial + Self.wallTimeSeconds(for: run)
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

    private static func wallTimeSeconds(for run: WorkflowRun) -> TimeInterval {
        if let wallTime = run.wallTime {
            return wallTime
        }
        return run.steps.reduce(0) { $0 + ($1.wallTime ?? 0) }
    }

    private static func peakMemoryBytes(for runs: [WorkflowRun]) -> UInt64? {
        runs
            .flatMap(\.steps)
            .compactMap(\.peakMemoryBytes)
            .max()
    }
}
