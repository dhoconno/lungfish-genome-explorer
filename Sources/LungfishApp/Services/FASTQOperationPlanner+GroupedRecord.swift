// FASTQOperationPlanner+GroupedRecord.swift - The record a grouped FASTQ result carries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A grouped result keeps its outputs in one folder. The commands that made them write a record
// beside each output. When the folder holds no record that names every output, the dispatcher
// writes one after the commands exit, from the commands it ran.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension FASTQOperationPlanner {
    func ensureGroupedResultProvenance(
        originalRequest: FASTQOperationLaunchRequest,
        resolvedRequest: FASTQOperationLaunchRequest,
        invocations: [FASTQCLIInvocation],
        outputURLs: [URL],
        outputDirectory: URL
    ) throws {
        let existingEnvelope = ProvenanceRecorder.loadEnvelope(from: outputDirectory)

        let missingProvenance = outputURLs.filter { !hasDiscoverableProvenance(forGroupedOutput: $0) }
        guard missingProvenance.isEmpty else {
            throw ProvenanceRehydrationError.missingSourceProvenance(
                "Missing provenance for grouped outputs: \(missingProvenance.map(\.path).joined(separator: ", "))"
            )
        }

        let outputPayloadURLs = uniqueExistingRegularPayloadURLs(from: outputURLs)
        guard !outputPayloadURLs.isEmpty else {
            throw ProvenanceRehydrationError.missingSourceProvenance(
                "No regular scientific payload files were discovered for grouped output \(outputDirectory.path)."
            )
        }

        if let existingEnvelope,
           groupedEnvelope(existingEnvelope, matches: outputPayloadURLs) {
            return
        }

        let inputPayloadURLs = uniqueExistingRegularPayloadURLs(from: originalRequest.provenanceInputURLs)
        let inputDescriptors = try inputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, role: .input)
        }
        let outputDescriptors = try outputPayloadURLs.map {
            try ProvenanceFileDescriptor.file(url: $0, role: .output)
        }
        let commandLines = invocations.map { invocation in
            let subcommandParts = invocation.subcommand
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            return [CLICommandIdentity.executableName] + subcommandParts + invocation.arguments
        }
        let argv = commandLines.count == 1
            ? (commandLines.first ?? [CLICommandIdentity.executableName, "fastq"])
            : [
                CLICommandIdentity.executableName,
                "gui",
                "fastq-grouped-result",
                "--operation",
                resolvedRequest.batchManifestOperationKind,
            ]
        let reproducibleCommand = commandLines
            .map { $0.map(shellEscape).joined(separator: " ") }
            .joined(separator: " && ")
        var parameters = Dictionary(
            uniqueKeysWithValues: resolvedRequest.batchManifestParameters.map { key, value in
                (key, ParameterValue.string(value))
            }
        )
        parameters["operationKind"] = .string(resolvedRequest.batchManifestOperationKind)
        parameters["outputDirectory"] = .file(outputDirectory)
        parameters["outputMode"] = .string(FASTQOperationOutputMode.groupedResult.rawValue)
        parameters["outputCount"] = .integer(outputURLs.count)

        let step = ProvenanceStep(
            toolName: "lungfish gui grouped FASTQ operation",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0
        )
        let now = Date()
        let envelope = try ProvenanceRunBuilder(
            workflowName: "\(resolvedRequest.batchManifestOperationKind) grouped FASTQ operation",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish gui grouped FASTQ operation",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .reproducibleCommand(reproducibleCommand)
        .options(explicit: parameters, defaults: [:], resolved: parameters)
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, startedAt: now, endedAt: now)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: outputDirectory)
    }

    private func groupedEnvelope(_ envelope: ProvenanceEnvelope, matches outputPayloadURLs: [URL]) -> Bool {
        let expectedPaths = Set(outputPayloadURLs.map { $0.standardizedFileURL.path })
        let recordedPaths = Set(((envelope.output.map { [$0.path] } ?? [])
            + envelope.outputs.map(\.path)
            + envelope.steps.flatMap { $0.outputs.map(\.path) })
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return expectedPaths.isSubset(of: recordedPaths)
    }

    private func hasDiscoverableProvenance(forGroupedOutput outputURL: URL) -> Bool {
        if ProvenanceRecorder.loadEnvelope(from: outputURL) != nil {
            return true
        }
        if isDirectory(outputURL) {
            if let primaryURL = SequenceInputResolver.resolvePrimarySequenceURL(for: outputURL),
               let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: primaryURL),
               provenanceSidecar(resolved.sidecarURL, isLocalTo: outputURL) {
                return true
            }
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: outputURL) {
                return provenanceSidecar(resolved.sidecarURL, isLocalTo: outputURL)
            }
            return false
        }
        return ProvenanceRecorder.findProvenance(forFile: outputURL) != nil
    }

    private func provenanceSidecar(_ sidecarURL: URL, isLocalTo outputURL: URL) -> Bool {
        let sidecarPath = sidecarURL.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        return sidecarPath == outputPath
            || sidecarPath.hasPrefix(outputPath + "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func uniqueExistingRegularPayloadURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .flatMap(Self.regularPayloadURLs)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
