// FASTQOperationPlanner+GroupedRecord.swift - The record a grouped FASTQ result carries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A grouped result keeps its outputs in one folder. The commands that made them write a record
// beside each output. When the folder holds no record that names every output, the dispatcher
// writes one after the commands exit, from the commands it ran. The record names only commands
// that exist (decision D2 of Phase 2.8). FASTQOperationGroupedRecordTests pins its shape.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension FASTQOperationPlanner {
    /// What the record's run and each of its steps are called. It labels the dispatcher's grouping
    /// of the commands and is never an argv, so it names no command.
    private static let groupedOperationToolName = "lungfish gui grouped FASTQ operation"

    /// Writes the record of a grouped result unless its folder already holds one that names every output.
    ///
    /// The record holds one step for each invocation, with the argv the dispatcher ran. The run command
    /// is that argv when there was one invocation. When there were several, no `lungfish-cli` command
    /// runs them as a group, so the run command is the shell that runs them in order, and the
    /// reproducible command is the same script in both shapes. A call with no invocation writes
    /// nothing, because a record of a finished result must name the command that made it.
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

        let commandLines = Self.commandLines(for: invocations)
        guard !commandLines.isEmpty else {
            throw ProvenanceRehydrationError.missingSourceProvenance(
                "No lungfish-cli command ran for grouped output \(outputDirectory.path)."
            )
        }
        let script = Self.script(for: commandLines)
        // The shell form is what `AssembleCommand` and `CLISequenceInputMaterialization` record for several commands.
        let runArgv = commandLines.count == 1 ? commandLines[0] : ["/bin/sh", "-lc", script]
        var parameters = Dictionary(
            uniqueKeysWithValues: resolvedRequest.batchManifestParameters.map { key, value in
                (key, ParameterValue.string(value))
            }
        )
        parameters["operationKind"] = .string(resolvedRequest.batchManifestOperationKind)
        parameters["outputDirectory"] = .file(outputDirectory)
        parameters["outputMode"] = .string(FASTQOperationOutputMode.groupedResult.rawValue)
        parameters["outputCount"] = .integer(outputURLs.count)

        var builder = ProvenanceRunBuilder(
            workflowName: "\(resolvedRequest.batchManifestOperationKind) grouped FASTQ operation",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: Self.groupedOperationToolName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(runArgv)
        .reproducibleCommand(script)
        .options(explicit: parameters, defaults: [:], resolved: parameters)
        .runtime(ProvenanceRuntimeIdentity())

        let inputPayloadURLs = uniqueExistingRegularPayloadURLs(from: originalRequest.provenanceInputURLs)
        if commandLines.count == 1 {
            // The one step is the whole run, so it lists the run's files, as this record always did.
            let inputs = try inputPayloadURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .input) }
            let outputs = try outputPayloadURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .output) }
            builder = builder.step(Self.groupedStep(argv: commandLines[0], inputs: inputs, outputs: outputs))
        } else {
            // This call is not told which command read or wrote which file, and a step that listed
            // them all would claim files its command never touched. The run lists the files and
            // each step names only its command.
            for url in inputPayloadURLs { builder = try builder.input(url, role: .input) }
            for url in outputPayloadURLs { builder = try builder.output(url, role: .output) }
            for argv in commandLines { builder = builder.step(Self.groupedStep(argv: argv)) }
        }
        let now = Date()
        let envelope = try builder.complete(exitStatus: 0, startedAt: now, endedAt: now)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: outputDirectory)
    }

    /// One argv for each invocation, in the order they ran. Each starts with `lungfish-cli`, and a
    /// subcommand of several words becomes several arguments, so the shipped parser reads it back.
    private static func commandLines(for invocations: [FASTQCLIInvocation]) -> [[String]] {
        invocations.map { invocation in
            let subcommandParts = invocation.subcommand
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            return [CLICommandIdentity.executableName] + subcommandParts + invocation.arguments
        }
    }

    /// The commands as one shell script, which stops at the first command that fails, as the run does.
    private static func script(for commandLines: [[String]]) -> String {
        commandLines
            .map { $0.map(shellEscape).joined(separator: " ") }
            .joined(separator: " && ")
    }

    private static func groupedStep(
        argv: [String],
        inputs: [ProvenanceFileDescriptor] = [],
        outputs: [ProvenanceFileDescriptor] = []
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: groupedOperationToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0
        )
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
