// UniversalSearchIndexProvenanceWriter.swift - Provenance for project universal-search indexes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct UniversalSearchIndexProvenanceRequest: Sendable {
    public let workflowName: String
    public let toolName: String
    public let toolKind: String
    public let projectURL: URL
    public let databaseURL: URL
    public let operation: String
    public let argv: [String]
    public let explicitOptions: [String: ParameterValue]
    public let defaults: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]
    public let buildStats: ProjectUniversalSearchBuildStats?
    public let startedAt: Date
    public let completedAt: Date

    public init(
        workflowName: String,
        toolName: String,
        toolKind: String,
        projectURL: URL,
        databaseURL: URL,
        operation: String,
        argv: [String],
        explicitOptions: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:],
        buildStats: ProjectUniversalSearchBuildStats? = nil,
        startedAt: Date,
        completedAt: Date
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.toolKind = toolKind
        self.projectURL = projectURL
        self.databaseURL = databaseURL
        self.operation = operation
        self.argv = argv
        self.explicitOptions = explicitOptions
        self.defaults = defaults
        self.resolvedDefaults = resolvedDefaults
        self.buildStats = buildStats
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum UniversalSearchIndexProvenanceWriter {
    @discardableResult
    public static func write(_ request: UniversalSearchIndexProvenanceRequest) throws -> URL {
        let projectURL = request.projectURL.standardizedFileURL
        let databaseURL = request.databaseURL.standardizedFileURL
        let projectInput = ProvenanceFileDescriptor(
            fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(
                url: projectURL,
                format: .unknown,
                role: .input
            )
        )
        let outputs = try sqliteOutputDescriptors(for: databaseURL)
        let primaryOutput = try ProvenanceFileDescriptor.file(
            url: databaseURL,
            format: .sqlite,
            role: .output
        )
        let options = ProvenanceOptions(
            explicit: request.explicitOptions.merging(["operation": .string(request.operation)]) { current, _ in current },
            defaults: request.defaults,
            resolvedDefaults: resolvedOptions(from: request)
        )
        let step = ProvenanceStep(
            toolName: request.toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: request.argv,
            durableReplayArgv: request.argv,
            inputs: [projectInput],
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            startedAt: request.startedAt,
            completedAt: request.completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: request.startedAt,
            workflowName: request.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: request.toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: request.toolName,
                version: WorkflowRun.currentAppVersion,
                kind: request.toolKind
            ),
            argv: request.argv,
            durableReplayArgv: request.argv,
            options: options,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: [projectInput] + outputs,
            output: primaryOutput,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            exitStatus: 0
        )

        return try ProvenanceWriter().write(
            envelope,
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: databaseURL)
        )
    }

    private static func sqliteOutputDescriptors(for databaseURL: URL) throws -> [ProvenanceFileDescriptor] {
        var descriptors = [
            try ProvenanceFileDescriptor.file(url: databaseURL, format: .sqlite, role: .output)
        ]
        for companionURL in sqliteCompanionURLs(for: databaseURL) where FileManager.default.fileExists(atPath: companionURL.path) {
            descriptors.append(
                try ProvenanceFileDescriptor.file(url: companionURL, format: .sqlite, role: .output)
            )
        }
        return descriptors
    }

    private static func sqliteCompanionURLs(for databaseURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    private static func resolvedOptions(
        from request: UniversalSearchIndexProvenanceRequest
    ) -> [String: ParameterValue] {
        var resolved = request.defaults
        for (key, value) in request.explicitOptions {
            resolved[key] = value
        }
        for (key, value) in request.resolvedDefaults {
            resolved[key] = value
        }
        resolved["operation"] = .string(request.operation)
        if let buildStats = request.buildStats {
            resolved["indexedEntities"] = .integer(buildStats.indexedEntities)
            resolved["indexedAttributes"] = .integer(buildStats.indexedAttributes)
            resolved["indexDurationSeconds"] = .number(buildStats.durationSeconds)
            resolved["perKindCounts"] = .dictionary(
                buildStats.perKindCounts.mapValues { .integer($0) }
            )
        }
        return resolved
    }
}
