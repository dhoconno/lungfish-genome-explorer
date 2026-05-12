// ProvenanceRehydrator.swift - Rewrites staged CLI provenance for GUI-owned bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceRehydrationError: Error, LocalizedError, Sendable, Equatable {
    case missingSourceProvenance(String)
    case outputPathNotMapped(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceProvenance(let directory):
            return "No readable provenance sidecar exists in \(directory)."
        case .outputPathNotMapped(let path):
            return "Provenance output path was not mapped into the final bundle: \(path)"
        }
    }
}

public enum ProvenanceRehydrator {
    @discardableResult
    public static func rehydrate(
        sourceDirectory: URL,
        finalDirectory: URL,
        pathMap: [String: String]
    ) throws -> ProvenanceEnvelope {
        let sourceProvenanceURL = sourceDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard FileManager.default.isReadableFile(atPath: sourceProvenanceURL.path),
              let sourceEnvelope = try ProvenanceEnvelopeReader.load(from: sourceDirectory) else {
            throw ProvenanceRehydrationError.missingSourceProvenance(sourceDirectory.path)
        }

        let rehydrated = try ProvenanceEnvelope(
            schemaVersion: sourceEnvelope.schemaVersion,
            id: sourceEnvelope.id,
            createdAt: sourceEnvelope.createdAt,
            workflowName: sourceEnvelope.workflowName,
            workflowVersion: sourceEnvelope.workflowVersion,
            toolName: sourceEnvelope.toolName,
            toolVersion: sourceEnvelope.toolVersion,
            tool: sourceEnvelope.tool,
            argv: sourceEnvelope.argv,
            reproducibleCommand: sourceEnvelope.reproducibleCommand,
            options: sourceEnvelope.options,
            runtimeIdentity: sourceEnvelope.runtimeIdentity,
            files: rewriteTopLevelFiles(
                sourceEnvelope.files,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenanceURL.path
            ),
            output: sourceEnvelope.output.map {
                try rewriteOutputDescriptor(
                    $0,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenanceURL.path
                )
            },
            outputs: sourceEnvelope.outputs.map {
                try rewriteOutputDescriptor(
                    $0,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenanceURL.path
                )
            },
            steps: sourceEnvelope.steps.map {
                try rewriteStep(
                    $0,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenanceURL.path
                )
            },
            wallTimeSeconds: sourceEnvelope.wallTimeSeconds,
            exitStatus: sourceEnvelope.exitStatus,
            stderr: sourceEnvelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )

        try ProvenanceWriter(signingProvider: nil).write(rehydrated, to: finalDirectory)
        return rehydrated
    }

    private static func rewriteTopLevelFiles(
        _ descriptors: [ProvenanceFileDescriptor],
        pathMap: [String: String],
        sourceProvenancePath: String
    ) throws -> [ProvenanceFileDescriptor] {
        try descriptors.map { descriptor in
            if descriptor.role == .output {
                return try rewriteOutputDescriptor(
                    descriptor,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenancePath
                )
            }
            return try rewriteInputDescriptor(
                descriptor,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenancePath
            )
        }
    }

    private static func rewriteStep(
        _ step: ProvenanceStep,
        pathMap: [String: String],
        sourceProvenancePath: String
    ) throws -> ProvenanceStep {
        ProvenanceStep(
            id: step.id,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            argv: step.argv,
            reproducibleCommand: step.reproducibleCommand,
            inputs: try step.inputs.map {
                try rewriteInputDescriptor(
                    $0,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenancePath
                )
            },
            outputs: try step.outputs.map {
                try rewriteOutputDescriptor(
                    $0,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenancePath
                )
            },
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            stderr: step.stderr,
            dependsOn: step.dependsOn,
            startedAt: step.startedAt,
            completedAt: step.completedAt
        )
    }

    private static func rewriteInputDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        pathMap: [String: String],
        sourceProvenancePath: String
    ) throws -> ProvenanceFileDescriptor {
        guard mappedPath(for: descriptor.path, in: pathMap) != nil else {
            return descriptor
        }
        return try rewriteMappedDescriptor(
            descriptor,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenancePath
        )
    }

    private static func rewriteOutputDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        pathMap: [String: String],
        sourceProvenancePath: String
    ) throws -> ProvenanceFileDescriptor {
        guard mappedPath(for: descriptor.path, in: pathMap) != nil else {
            throw ProvenanceRehydrationError.outputPathNotMapped(descriptor.path)
        }
        return try rewriteMappedDescriptor(
            descriptor,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenancePath
        )
    }

    private static func rewriteMappedDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        pathMap: [String: String],
        sourceProvenancePath: String
    ) throws -> ProvenanceFileDescriptor {
        guard let finalPath = mappedPath(for: descriptor.path, in: pathMap) else {
            return descriptor
        }
        let finalURL = URL(fileURLWithPath: finalPath)
        return try ProvenanceFileDescriptor.file(
            url: finalURL,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.path,
            sourceProvenancePath: sourceProvenancePath
        )
    }

    private static func mappedPath(for path: String, in pathMap: [String: String]) -> String? {
        if let mapped = pathMap[path] {
            return mapped
        }
        return pathMap[URL(fileURLWithPath: path).standardizedFileURL.path]
    }
}
