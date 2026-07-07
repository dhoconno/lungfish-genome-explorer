// BundleAlignmentFilterProvenanceWriter.swift - Canonical provenance for filtered BAM tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

enum BundleAlignmentFilterProvenanceWriter {
    private struct DescriptorSource {
        let url: URL
        let format: FileFormat?
        let role: FileRole
    }

    static func write(
        target: ResolvedAlignmentFilterTarget,
        sourceTrack: AlignmentTrackInfo,
        sourceAlignmentPath: String,
        sourceIndexPath: String,
        referenceFastaPath: String?,
        outputTrackName: String,
        outputTrackIDWasExplicit: Bool,
        filterRequest: AlignmentFilterRequest,
        attachment: PreparedAlignmentAttachmentResult,
        commandHistory: [AlignmentCommandExecutionRecord],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let bundleURL = target.bundleURL.standardizedFileURL
        var inputSources = [
            DescriptorSource(url: URL(fileURLWithPath: sourceAlignmentPath), format: .bam, role: .input),
            DescriptorSource(url: URL(fileURLWithPath: sourceIndexPath), format: .unknown, role: .index),
        ]
        if let referenceFastaPath {
            inputSources.append(DescriptorSource(
                url: URL(fileURLWithPath: referenceFastaPath),
                format: .fasta,
                role: .reference
            ))
        }
        let outputSources = [
            DescriptorSource(url: attachment.bamURL, format: .bam, role: .output),
            DescriptorSource(url: attachment.indexURL, format: .unknown, role: .output),
            DescriptorSource(url: attachment.metadataDBURL, format: .sqlite, role: .output),
            DescriptorSource(url: bundleURL.appendingPathComponent(BundleManifest.filename), format: .json, role: .output),
        ]
        let inputDescriptors = try inputSources.map(descriptor)
        let outputDescriptors = try outputSources.map(descriptor)
        let exactArgv = filterArgv(
            target: target,
            sourceTrackID: sourceTrack.id,
            outputTrackID: attachment.trackInfo.id,
            includeOutputTrackID: outputTrackIDWasExplicit,
            outputTrackName: outputTrackName,
            filterRequest: filterRequest
        )
        let durableReplayArgv = filterArgv(
            target: target,
            sourceTrackID: sourceTrack.id,
            outputTrackID: attachment.trackInfo.id,
            includeOutputTrackID: true,
            outputTrackName: outputTrackName,
            filterRequest: filterRequest
        )

        let wallTimeSeconds = completedAt.timeIntervalSince(startedAt)
        var previousStepID: UUID?
        var steps: [ProvenanceStep] = []
        for command in commandHistory {
            let stepID = UUID()
            steps.append(ProvenanceStep(
                id: stepID,
                toolName: command.tool,
                toolVersion: command.toolVersion ?? "unknown",
                argv: [command.tool] + command.arguments,
                inputs: try commandInputDescriptors(for: command),
                outputs: try commandOutputDescriptors(for: command),
                exitStatus: command.exitStatus ?? 0,
                wallTimeSeconds: command.wallTimeSeconds,
                stderr: command.stderr,
                dependsOn: previousStepID.map { [$0] } ?? [],
                startedAt: command.startedAt,
                completedAt: command.completedAt
            ))
            previousStepID = stepID
        }

        steps.append(ProvenanceStep(
            toolName: "lungfish bam filter",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: exactArgv,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: wallTimeSeconds,
            stderr: nil,
            dependsOn: previousStepID.map { [$0] } ?? [],
            startedAt: startedAt,
            completedAt: completedAt
        ))

        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish bam filter",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish bam filter",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(exactArgv)
        .durableReplayArgv(durableReplayArgv)
        .options(
            explicit: explicitOptions(
                target: target,
                sourceTrackID: sourceTrack.id,
                outputTrackID: attachment.trackInfo.id,
                outputTrackIDWasExplicit: outputTrackIDWasExplicit,
                outputTrackName: outputTrackName
            ),
            defaults: defaultOptions(),
            resolved: resolvedOptions(
                target: target,
                sourceTrack: sourceTrack,
                sourceAlignmentPath: sourceAlignmentPath,
                sourceIndexPath: sourceIndexPath,
                referenceFastaPath: referenceFastaPath,
                outputTrackName: outputTrackName,
                filterRequest: filterRequest,
                attachment: attachment,
                commandHistory: commandHistory
            )
        )
        .runtime(ProvenanceRuntimeIdentity())

        for source in inputSources {
            builder = try builder.input(source.url, format: source.format, role: source.role)
        }
        for source in outputSources {
            builder = try builder.output(source.url, format: source.format, role: source.role)
        }
        for step in steps {
            builder = builder.step(step)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: nil,
            startedAt: startedAt,
            endedAt: completedAt
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private static func descriptor(_ source: DescriptorSource) throws -> ProvenanceFileDescriptor {
        try ProvenanceFileDescriptor.file(url: source.url, format: source.format, role: source.role)
    }

    private static func commandInputDescriptors(
        for command: AlignmentCommandExecutionRecord
    ) throws -> [ProvenanceFileDescriptor] {
        if let inputDescriptor = command.inputDescriptor {
            return [inputDescriptor] + command.additionalInputDescriptors
        }
        return try commandDescriptors(path: command.inputFile, role: .input) + command.additionalInputDescriptors
    }

    private static func commandOutputDescriptors(
        for command: AlignmentCommandExecutionRecord
    ) throws -> [ProvenanceFileDescriptor] {
        if let outputDescriptor = command.outputDescriptor {
            return [outputDescriptor]
        }
        return try commandDescriptors(path: command.outputFile, role: .output)
    }

    private static func commandDescriptors(path: String?, role: FileRole) throws -> [ProvenanceFileDescriptor] {
        guard let path else { return [] }
        return [try alignmentCommandFileDescriptor(path: path, role: role)]
    }

    private static func filterArgv(
        target: ResolvedAlignmentFilterTarget,
        sourceTrackID: String,
        outputTrackID: String,
        includeOutputTrackID: Bool,
        outputTrackName: String,
        filterRequest: AlignmentFilterRequest
    ) -> [String] {
        var argv = [
            CLICommandIdentity.executableName,
            "bam",
            "filter",
        ]
        if let mappingResultURL = target.mappingResultURL {
            argv += ["--mapping-result", mappingResultURL.path]
        } else {
            argv += ["--bundle", target.bundleURL.path]
        }
        argv += [
            "--alignment-track",
            sourceTrackID,
        ]
        if includeOutputTrackID {
            argv += [
                "--output-track-id",
                outputTrackID,
            ]
        }
        argv += [
            "--output-track-name",
            outputTrackName,
        ]
        if filterRequest.mappedOnly {
            argv.append("--mapped-only")
        }
        if filterRequest.primaryOnly {
            argv.append("--primary-only")
        }
        if let minimumMAPQ = filterRequest.minimumMAPQ {
            argv += ["--min-mapq", String(minimumMAPQ)]
        }
        switch filterRequest.duplicateMode {
        case .exclude:
            argv.append("--exclude-marked-duplicates")
        case .remove:
            argv.append("--remove-duplicates")
        case nil:
            break
        }
        switch filterRequest.identityFilter {
        case .exactMatch:
            argv.append("--exact-match")
        case .minimumPercentIdentity(let threshold):
            argv += ["--min-percent-identity", AlignmentFilterIdentityFilter.formattedThreshold(threshold)]
        case nil:
            break
        }
        return argv
    }

    private static func explicitOptions(
        target: ResolvedAlignmentFilterTarget,
        sourceTrackID: String,
        outputTrackID: String,
        outputTrackIDWasExplicit: Bool,
        outputTrackName: String
    ) -> [String: ParameterValue] {
        var explicit: [String: ParameterValue] = [
            "targetKind": .string(target.mappingResultURL == nil ? "bundle" : "mapping_result"),
            "sourceTrackID": .string(sourceTrackID),
            "outputTrackName": .string(outputTrackName),
        ]
        if let mappingResultURL = target.mappingResultURL {
            explicit["mappingResultPath"] = .file(mappingResultURL)
        } else {
            explicit["bundlePath"] = .file(target.bundleURL)
        }
        if outputTrackIDWasExplicit {
            explicit["outputTrackID"] = .string(outputTrackID)
        }
        return explicit
    }

    private static func defaultOptions() -> [String: ParameterValue] {
        [
            "mappedOnly": .boolean(false),
            "primaryOnly": .boolean(false),
            "minimumMAPQ": .null,
            "duplicateMode": .string("none"),
            "identityFilter": .string("none"),
            "region": .null,
            "outputTrackID": .null,
        ]
    }

    private static func resolvedOptions(
        target: ResolvedAlignmentFilterTarget,
        sourceTrack: AlignmentTrackInfo,
        sourceAlignmentPath: String,
        sourceIndexPath: String,
        referenceFastaPath: String?,
        outputTrackName: String,
        filterRequest: AlignmentFilterRequest,
        attachment: PreparedAlignmentAttachmentResult,
        commandHistory: [AlignmentCommandExecutionRecord]
    ) -> [String: ParameterValue] {
        var resolved: [String: ParameterValue] = [
            "targetKind": .string(target.mappingResultURL == nil ? "bundle" : "mapping_result"),
            "bundlePath": .file(target.bundleURL),
            "sourceTrackID": .string(sourceTrack.id),
            "sourceTrackName": .string(sourceTrack.name),
            "sourceAlignmentPath": .file(URL(fileURLWithPath: sourceAlignmentPath)),
            "sourceIndexPath": .file(URL(fileURLWithPath: sourceIndexPath)),
            "outputTrackID": .string(attachment.trackInfo.id),
            "outputTrackName": .string(outputTrackName),
            "bamPath": .file(attachment.bamURL),
            "indexPath": .file(attachment.indexURL),
            "metadataDBPath": .file(attachment.metadataDBURL),
            "mappedOnly": .boolean(filterRequest.mappedOnly),
            "primaryOnly": .boolean(filterRequest.primaryOnly),
            "minimumMAPQ": filterRequest.minimumMAPQ.map(ParameterValue.integer) ?? .null,
            "duplicateMode": .string(filterRequest.duplicateMode?.rawValue ?? "none"),
            "identityFilter": .string(filterRequest.identityFilter?.metadataValue ?? "none"),
            "region": filterRequest.region.map(ParameterValue.string) ?? .null,
            "filterSummary": .string(filterRequest.derivedAlignmentSummary),
            "commandHistory": .array(commandHistory.map { .string($0.commandLine) }),
        ]
        if let mappingResultURL = target.mappingResultURL {
            resolved["mappingResultPath"] = .file(mappingResultURL)
        }
        if let referenceFastaPath {
            resolved["referenceFastaPath"] = .file(URL(fileURLWithPath: referenceFastaPath))
        }
        return resolved
    }
}
