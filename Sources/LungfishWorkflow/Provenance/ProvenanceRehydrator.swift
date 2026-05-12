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
        try rehydrate(
            sourceDirectory: sourceDirectory,
            finalDirectory: finalDirectory,
            pathMap: pathMap,
            outputMode: .strict
        )
    }

    @discardableResult
    public static func rehydrateSelectedOutputs(
        sourceDirectory: URL,
        finalDirectory: URL,
        pathMap: [String: String]
    ) throws -> ProvenanceEnvelope {
        try rehydrate(
            sourceDirectory: sourceDirectory,
            finalDirectory: finalDirectory,
            pathMap: pathMap,
            outputMode: .selectedOnly
        )
    }

    private static func rehydrate(
        sourceDirectory: URL,
        finalDirectory: URL,
        pathMap: [String: String],
        outputMode: OutputMode
    ) throws -> ProvenanceEnvelope {
        let sourceProvenanceURL = sourceDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard FileManager.default.isReadableFile(atPath: sourceProvenanceURL.path),
              let sourceEnvelope = try ProvenanceEnvelopeReader.load(from: sourceDirectory) else {
            throw ProvenanceRehydrationError.missingSourceProvenance(sourceDirectory.path)
        }
        let outputs = try rewriteOutputs(
            sourceEnvelope.outputs,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenanceURL.path,
            outputMode: outputMode
        )
        let output = try rewritePrimaryOutput(
            sourceEnvelope.output,
            rewrittenOutputs: outputs,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenanceURL.path,
            outputMode: outputMode
        )
        let steps = try rewriteSteps(
            sourceEnvelope.steps,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenanceURL.path,
            outputMode: outputMode
        )

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
                sourceProvenancePath: sourceProvenanceURL.path,
                outputMode: outputMode
            ),
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: sourceEnvelope.wallTimeSeconds,
            exitStatus: sourceEnvelope.exitStatus,
            stderr: sourceEnvelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )

        try ProvenanceWriter(signingProvider: nil).write(rehydrated, to: finalDirectory)
        return rehydrated
    }

    private enum OutputMode {
        case strict
        case selectedOnly
    }

    private static func rewriteTopLevelFiles(
        _ descriptors: [ProvenanceFileDescriptor],
        pathMap: [String: String],
        sourceProvenancePath: String,
        outputMode: OutputMode
    ) throws -> [ProvenanceFileDescriptor] {
        try descriptors.compactMap { descriptor in
            if descriptor.role == .output {
                return try rewriteOutputDescriptor(
                    descriptor,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenancePath,
                    outputMode: outputMode
                )
            }
            return try rewriteInputDescriptor(
                descriptor,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenancePath
            )
        }
    }

    private static func rewritePrimaryOutput(
        _ output: ProvenanceFileDescriptor?,
        rewrittenOutputs: [ProvenanceFileDescriptor],
        pathMap: [String: String],
        sourceProvenancePath: String,
        outputMode: OutputMode
    ) throws -> ProvenanceFileDescriptor? {
        guard let output else {
            return rewrittenOutputs.first
        }
        if outputMode == .selectedOnly, mappedPath(for: output.path, in: pathMap) == nil {
            return rewrittenOutputs.first
        }
        return try rewriteOutputDescriptor(
            output,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenancePath,
            outputMode: outputMode
        )
    }

    private static func rewriteOutputs(
        _ outputs: [ProvenanceFileDescriptor],
        pathMap: [String: String],
        sourceProvenancePath: String,
        outputMode: OutputMode
    ) throws -> [ProvenanceFileDescriptor] {
        let rewritten = try outputs.compactMap {
            try rewriteOutputDescriptor(
                $0,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenancePath,
                outputMode: outputMode
            )
        }
        if outputMode == .selectedOnly, rewritten.isEmpty, let firstOutput = outputs.first {
            throw ProvenanceRehydrationError.outputPathNotMapped(firstOutput.path)
        }
        return rewritten
    }

    private static func rewriteSteps(
        _ steps: [ProvenanceStep],
        pathMap: [String: String],
        sourceProvenancePath: String,
        outputMode: OutputMode
    ) throws -> [ProvenanceStep] {
        let rewritten = try steps.compactMap { step -> ProvenanceStep? in
            let rewrittenStep = try rewriteStep(
                step,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenancePath,
                outputMode: outputMode
            )
            if outputMode == .selectedOnly, step.outputs.isEmpty == false, rewrittenStep.outputs.isEmpty {
                return nil
            }
            return rewrittenStep
        }
        return rewritten
    }

    private static func rewriteStep(
        _ step: ProvenanceStep,
        pathMap: [String: String],
        sourceProvenancePath: String,
        outputMode: OutputMode
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
            outputs: try step.outputs.compactMap {
                try rewriteOutputDescriptor(
                    $0,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenancePath,
                    outputMode: outputMode
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
        sourceProvenancePath: String,
        outputMode: OutputMode
    ) throws -> ProvenanceFileDescriptor? {
        guard mappedPath(for: descriptor.path, in: pathMap) != nil else {
            if outputMode == .selectedOnly {
                return nil
            }
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
