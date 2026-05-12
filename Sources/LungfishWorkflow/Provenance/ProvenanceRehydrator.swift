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
        let selectedProjection = outputMode == .selectedOnly
            ? selectedProjection(for: sourceEnvelope.steps, pathMap: pathMap)
            : nil
        let outputs = try rewriteOutputs(
            sourceEnvelope.outputs,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenanceURL.path,
            selectedProjection: selectedProjection
        )
        let output = try rewritePrimaryOutput(
            sourceEnvelope.output,
            rewrittenOutputs: outputs,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenanceURL.path,
            selectedProjection: selectedProjection
        )
        let steps = try rewriteSteps(
            sourceEnvelope.steps,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenanceURL.path,
            selectedProjection: selectedProjection
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
                selectedProjection: selectedProjection
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

    private struct SelectedProjection {
        let retainedStepIDs: Set<UUID>
        let retainedInputPaths: Set<String>
        let retainedIntermediateOutputPaths: Set<String>
    }

    private static func selectedProjection(
        for steps: [ProvenanceStep],
        pathMap: [String: String]
    ) -> SelectedProjection {
        var retainedStepIDs = Set<UUID>()

        for step in steps where step.outputs.contains(where: { mappedPath(for: $0.path, in: pathMap) != nil }) {
            retainedStepIDs.insert(step.id)
        }

        var changed = true
        while changed {
            changed = false
            let consumedInputPaths = Set(
                steps
                    .filter { retainedStepIDs.contains($0.id) }
                    .flatMap { $0.inputs.map(\.path) }
            )

            for step in steps where retainedStepIDs.contains(step.id) {
                for dependencyID in step.dependsOn where retainedStepIDs.insert(dependencyID).inserted {
                    changed = true
                }
            }

            for step in steps
                where !retainedStepIDs.contains(step.id)
                    && step.outputs.contains(where: { consumedInputPaths.contains($0.path) }) {
                retainedStepIDs.insert(step.id)
                changed = true
            }
        }

        let retainedSteps = steps.filter { retainedStepIDs.contains($0.id) }
        let consumedInputPaths = Set(retainedSteps.flatMap { $0.inputs.map(\.path) })
        let retainedOutputPaths = Set(retainedSteps.flatMap { $0.outputs.map(\.path) })
        let intermediateOutputPaths = consumedInputPaths
            .intersection(retainedOutputPaths)
            .filter { mappedPath(for: $0, in: pathMap) == nil }

        return SelectedProjection(
            retainedStepIDs: retainedStepIDs,
            retainedInputPaths: consumedInputPaths,
            retainedIntermediateOutputPaths: Set(intermediateOutputPaths)
        )
    }

    private static func rewriteTopLevelFiles(
        _ descriptors: [ProvenanceFileDescriptor],
        pathMap: [String: String],
        sourceProvenancePath: String,
        selectedProjection: SelectedProjection?
    ) throws -> [ProvenanceFileDescriptor] {
        try descriptors.compactMap { descriptor in
            if descriptor.role == .output {
                return try rewriteOutputDescriptor(
                    descriptor,
                    pathMap: pathMap,
                    sourceProvenancePath: sourceProvenancePath,
                    selectedProjection: selectedProjection,
                    preserveConsumedIntermediates: true
                )
            }
            if let selectedProjection,
               selectedProjection.retainedInputPaths.contains(descriptor.path) == false,
               mappedPath(for: descriptor.path, in: pathMap) == nil {
                return nil
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
        selectedProjection: SelectedProjection?
    ) throws -> ProvenanceFileDescriptor? {
        guard let output else {
            return rewrittenOutputs.first
        }
        if selectedProjection != nil, mappedPath(for: output.path, in: pathMap) == nil {
            return rewrittenOutputs.first
        }
        return try rewriteOutputDescriptor(
            output,
            pathMap: pathMap,
            sourceProvenancePath: sourceProvenancePath,
            selectedProjection: selectedProjection,
            preserveConsumedIntermediates: false
        )
    }

    private static func rewriteOutputs(
        _ outputs: [ProvenanceFileDescriptor],
        pathMap: [String: String],
        sourceProvenancePath: String,
        selectedProjection: SelectedProjection?
    ) throws -> [ProvenanceFileDescriptor] {
        let rewritten = try outputs.compactMap {
            try rewriteOutputDescriptor(
                $0,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenancePath,
                selectedProjection: selectedProjection,
                preserveConsumedIntermediates: false
            )
        }
        if selectedProjection != nil, rewritten.isEmpty, let firstOutput = outputs.first {
            throw ProvenanceRehydrationError.outputPathNotMapped(firstOutput.path)
        }
        return rewritten
    }

    private static func rewriteSteps(
        _ steps: [ProvenanceStep],
        pathMap: [String: String],
        sourceProvenancePath: String,
        selectedProjection: SelectedProjection?
    ) throws -> [ProvenanceStep] {
        let retainedSteps = selectedProjection.map { projection in
            steps.filter { projection.retainedStepIDs.contains($0.id) }
        } ?? steps
        return try retainedSteps.map { step in
            try rewriteStep(
                step,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenancePath,
                selectedProjection: selectedProjection
            )
        }
    }

    private static func rewriteStep(
        _ step: ProvenanceStep,
        pathMap: [String: String],
        sourceProvenancePath: String,
        selectedProjection: SelectedProjection?
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
                    selectedProjection: selectedProjection,
                    preserveConsumedIntermediates: true
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
        selectedProjection: SelectedProjection?,
        preserveConsumedIntermediates: Bool
    ) throws -> ProvenanceFileDescriptor? {
        guard mappedPath(for: descriptor.path, in: pathMap) != nil else {
            if preserveConsumedIntermediates,
               selectedProjection?.retainedIntermediateOutputPaths.contains(descriptor.path) == true {
                return descriptor
            }
            if selectedProjection != nil {
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
