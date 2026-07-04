// ScientificFileExportProvenance.swift - Canonical sidecars for app file exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

enum ScientificFileExportProvenance {
    struct Request {
        let workflowName: String
        let toolName: String
        let sourceURLs: [URL]
        let outputURL: URL
        let outputFormat: FileFormat
        let argv: [String]
        let explicitOptions: [String: ParameterValue]
        let defaults: [String: ParameterValue]
        let resolved: [String: ParameterValue]
        let startedAt: Date
        let completedAt: Date

        init(
            workflowName: String,
            toolName: String = "Lungfish.app",
            sourceURLs: [URL],
            outputURL: URL,
            outputFormat: FileFormat,
            argv: [String],
            explicitOptions: [String: ParameterValue] = [:],
            defaults: [String: ParameterValue] = [:],
            resolved: [String: ParameterValue] = [:],
            startedAt: Date,
            completedAt: Date = Date()
        ) {
            self.workflowName = workflowName
            self.toolName = toolName
            self.sourceURLs = sourceURLs
            self.outputURL = outputURL
            self.outputFormat = outputFormat
            self.argv = argv
            self.explicitOptions = explicitOptions
            self.defaults = defaults
            self.resolved = resolved
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }

    @discardableResult
    static func write(_ request: Request) throws -> URL {
        let inputDescriptors = request.sourceURLs.map { url in
            ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileRecord(url: url, role: .input),
                sourceProvenancePath: ProvenanceRecorder.findProvenanceEnvelope(for: url)?.sidecarURL.path
            )
        }
        let outputDescriptor = try ProvenanceFileDescriptor.file(
            url: request.outputURL,
            format: request.outputFormat,
            role: .output
        )
        let toolVersion = WorkflowRun.currentAppVersion
        let step = ProvenanceStep(
            toolName: request.toolName,
            toolVersion: toolVersion,
            argv: request.argv,
            durableReplayArgv: request.argv,
            inputs: inputDescriptors,
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            stderr: nil,
            startedAt: request.startedAt,
            completedAt: request.completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: request.startedAt,
            workflowName: request.workflowName,
            workflowVersion: toolVersion,
            toolName: request.toolName,
            toolVersion: toolVersion,
            tool: ProvenanceToolIdentity(name: request.toolName, version: toolVersion, kind: "gui"),
            argv: request.argv,
            durableReplayArgv: request.argv,
            options: ProvenanceOptions(
                explicit: request.explicitOptions,
                defaults: request.defaults,
                resolvedDefaults: request.resolved
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputDescriptors + [outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: request.completedAt.timeIntervalSince(request.startedAt),
            exitStatus: 0,
            stderr: nil
        )

        do {
            return try ProvenanceWriter(signingProvider: nil).write(
                envelope,
                toSidecar: ProvenanceRecorder.fileSidecarURL(for: request.outputURL)
            )
        } catch {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw error
        }
    }
}
