// MappedReadsAnnotationProvenanceWriter.swift - Canonical provenance for BAM annotation workflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

enum MappedReadsAnnotationProvenanceWriter {
    private struct DescriptorSource {
        let url: URL
        let format: FileFormat?
        let role: FileRole
    }

    static func writeMappedReads(
        request: MappedReadsAnnotationRequest,
        bundleURL: URL,
        sourceTrack: AlignmentTrackInfo,
        sourceAlignmentPath: String,
        sourceIndexPath: String?,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String,
        databaseURL: URL,
        viewArguments: [String],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let inputSources = mappedReadsInputs(
            sourceAlignmentPath: sourceAlignmentPath,
            sourceIndexPath: sourceIndexPath
        )
        let argv = mappedReadsArgv(
            request: request,
            bundleURL: bundleURL,
            outputTrackName: outputTrackName
        )
        try write(
            workflowName: "lungfish bam annotate",
            argv: argv,
            outputBundleURL: bundleURL,
            databaseURL: databaseURL,
            inputSources: inputSources,
            viewArguments: viewArguments,
            options: ProvenanceOptions(
                explicit: mappedReadsExplicitOptions(
                    request: request,
                    bundleURL: bundleURL,
                    outputTrackName: outputTrackName
                ),
                defaults: [
                    "primaryOnly": .boolean(false),
                    "includeSequence": .boolean(false),
                    "includeQualities": .boolean(false),
                    "replaceExisting": .boolean(false),
                ],
                resolvedDefaults: mappedReadsResolvedOptions(
                    request: request,
                    sourceTrack: sourceTrack,
                    sourceAlignmentPath: sourceAlignmentPath,
                    sourceIndexPath: sourceIndexPath,
                    outputTrackID: outputTrackID,
                    outputTrackName: outputTrackName,
                    relativeDatabasePath: relativeDatabasePath
                )
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    static func writeBestMappedReads(
        request: BestMappedReadsAnnotationRequest,
        sourceBundleURL: URL,
        outputBundleURL: URL,
        mappingResult: MappingResult,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String,
        databaseURL: URL,
        viewArguments: [String],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let inputSources = copiedBundleAnnotationInputs(
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            mappingResult: mappingResult
        )
        let argv = bestMappedReadsArgv(
            request: request,
            sourceBundleURL: sourceBundleURL,
            outputBundleURL: outputBundleURL,
            outputTrackName: outputTrackName
        )
        try write(
            workflowName: "lungfish bam annotate-best",
            argv: argv,
            outputBundleURL: outputBundleURL,
            databaseURL: databaseURL,
            inputSources: inputSources,
            viewArguments: viewArguments,
            options: ProvenanceOptions(
                explicit: copiedBundleExplicitOptions(
                    sourceBundleURL: sourceBundleURL,
                    mappingResultURL: request.mappingResultURL.standardizedFileURL,
                    outputBundleURL: outputBundleURL,
                    outputTrackName: outputTrackName,
                    outputTrackID: request.outputTrackID
                ),
                defaults: [
                    "primaryOnly": .boolean(false),
                    "replaceExisting": .boolean(false),
                ],
                resolvedDefaults: bestMappedReadsResolvedOptions(
                    request: request,
                    sourceBundleURL: sourceBundleURL,
                    outputBundleURL: outputBundleURL,
                    mappingResult: mappingResult,
                    outputTrackID: outputTrackID,
                    outputTrackName: outputTrackName,
                    relativeDatabasePath: relativeDatabasePath
                )
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    static func writeCDSBest(
        request: CDSBestAnnotationRequest,
        sourceBundleURL: URL,
        outputBundleURL: URL,
        mappingResult: MappingResult,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String,
        databaseURL: URL,
        viewArguments: [String],
        startedAt: Date,
        completedAt: Date
    ) throws {
        let inputSources = copiedBundleAnnotationInputs(
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            mappingResult: mappingResult
        )
        let argv = cdsBestArgv(
            request: request,
            sourceBundleURL: sourceBundleURL,
            outputBundleURL: outputBundleURL,
            outputTrackName: outputTrackName
        )
        try write(
            workflowName: "lungfish bam annotate-cds-best",
            argv: argv,
            outputBundleURL: outputBundleURL,
            databaseURL: databaseURL,
            inputSources: inputSources,
            viewArguments: viewArguments,
            options: ProvenanceOptions(
                explicit: copiedBundleExplicitOptions(
                    sourceBundleURL: sourceBundleURL,
                    mappingResultURL: request.mappingResultURL.standardizedFileURL,
                    outputBundleURL: outputBundleURL,
                    outputTrackName: outputTrackName,
                    outputTrackID: request.outputTrackID
                ),
                defaults: [
                    "includeSecondary": .boolean(false),
                    "includeSupplementary": .boolean(false),
                    "minimumQueryCoverage": .number(0.5),
                    "replaceExisting": .boolean(false),
                ],
                resolvedDefaults: cdsBestResolvedOptions(
                    request: request,
                    sourceBundleURL: sourceBundleURL,
                    outputBundleURL: outputBundleURL,
                    mappingResult: mappingResult,
                    outputTrackID: outputTrackID,
                    outputTrackName: outputTrackName,
                    relativeDatabasePath: relativeDatabasePath
                )
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private static func write(
        workflowName: String,
        argv: [String],
        outputBundleURL: URL,
        databaseURL: URL,
        inputSources: [DescriptorSource],
        viewArguments: [String],
        options: ProvenanceOptions,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let manifestURL = outputBundleURL.appendingPathComponent(BundleManifest.filename)
        let outputSources = [
            DescriptorSource(url: databaseURL, format: .sqlite, role: .output),
            DescriptorSource(url: manifestURL, format: .json, role: .output),
        ]
        let inputDescriptors = try inputSources.map(descriptor)
        let outputDescriptors = try outputSources.map(descriptor)
        let samtoolsStepID = UUID()
        let wallTimeSeconds = completedAt.timeIntervalSince(startedAt)
        let samtoolsStep = ProvenanceStep(
            id: samtoolsStepID,
            toolName: "samtools",
            toolVersion: "unknown",
            argv: ["samtools"] + viewArguments,
            inputs: inputDescriptors,
            outputs: [],
            exitStatus: 0,
            wallTimeSeconds: wallTimeSeconds,
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let annotationStep = ProvenanceStep(
            toolName: workflowName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: wallTimeSeconds,
            stderr: nil,
            dependsOn: [samtoolsStepID],
            startedAt: startedAt,
            completedAt: completedAt
        )

        var builder = ProvenanceRunBuilder(
            workflowName: workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: workflowName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .options(
            explicit: options.explicit,
            defaults: options.defaults,
            resolved: options.resolvedDefaults
        )
        .runtime(ProvenanceRuntimeIdentity())

        for source in inputSources {
            builder = try builder.input(source.url, format: source.format, role: source.role)
        }
        for source in outputSources {
            builder = try builder.output(source.url, format: source.format, role: source.role)
        }

        let envelope = try builder
            .step(samtoolsStep)
            .step(annotationStep)
            .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: outputBundleURL)
    }

    private static func descriptor(_ source: DescriptorSource) throws -> ProvenanceFileDescriptor {
        try ProvenanceFileDescriptor.file(url: source.url, format: source.format, role: source.role)
    }

    private static func mappedReadsInputs(
        sourceAlignmentPath: String,
        sourceIndexPath: String?
    ) -> [DescriptorSource] {
        var inputs = [
            DescriptorSource(url: URL(fileURLWithPath: sourceAlignmentPath), format: .bam, role: .input),
        ]
        if let sourceIndexPath {
            inputs.append(DescriptorSource(url: URL(fileURLWithPath: sourceIndexPath), format: .unknown, role: .index))
        }
        return inputs
    }

    private static func copiedBundleAnnotationInputs(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        mappingResult: MappingResult
    ) -> [DescriptorSource] {
        var inputs = [
            DescriptorSource(
                url: sourceBundleURL.appendingPathComponent(BundleManifest.filename),
                format: .json,
                role: .input
            ),
            DescriptorSource(url: mappingResult.bamURL, format: .bam, role: .input),
        ]
        if FileManager.default.fileExists(atPath: mappingResult.baiURL.path) {
            inputs.append(DescriptorSource(url: mappingResult.baiURL, format: .unknown, role: .index))
        }
        let mappingSidecarURL = mappingResultURL.appendingPathComponent("mapping-result.json")
        if FileManager.default.fileExists(atPath: mappingSidecarURL.path) {
            inputs.append(DescriptorSource(url: mappingSidecarURL, format: .json, role: .input))
        }
        return inputs
    }

    private static func mappedReadsArgv(
        request: MappedReadsAnnotationRequest,
        bundleURL: URL,
        outputTrackName: String
    ) -> [String] {
        var argv = [
            CLICommandIdentity.executableName,
            "bam",
            "annotate",
            "--bundle",
            bundleURL.path,
            "--alignment-track",
            request.sourceTrackID,
            "--output-track-name",
            outputTrackName,
        ]
        if let outputTrackID = trimmedOutputTrackID(request.outputTrackID) {
            argv += ["--output-track-id", outputTrackID]
        }
        if request.primaryOnly {
            argv.append("--primary-only")
        }
        if request.includeSequence {
            argv.append("--include-sequence")
        }
        if request.includeQualities {
            argv.append("--include-qualities")
        }
        if request.replaceExisting {
            argv.append("--replace")
        }
        return argv
    }

    private static func bestMappedReadsArgv(
        request: BestMappedReadsAnnotationRequest,
        sourceBundleURL: URL,
        outputBundleURL: URL,
        outputTrackName: String
    ) -> [String] {
        var argv = copiedBundleBaseArgv(
            subcommand: "annotate-best",
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            outputBundleURL: outputBundleURL,
            outputTrackName: outputTrackName,
            outputTrackID: request.outputTrackID
        )
        if request.primaryOnly {
            argv.append("--primary-only")
        }
        if request.replaceExisting {
            argv.append("--replace")
        }
        return argv
    }

    private static func cdsBestArgv(
        request: CDSBestAnnotationRequest,
        sourceBundleURL: URL,
        outputBundleURL: URL,
        outputTrackName: String
    ) -> [String] {
        var argv = copiedBundleBaseArgv(
            subcommand: "annotate-cds-best",
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            outputBundleURL: outputBundleURL,
            outputTrackName: outputTrackName,
            outputTrackID: request.outputTrackID
        )
        if request.includeSecondary {
            argv.append("--include-secondary")
        }
        if request.includeSupplementary {
            argv.append("--include-supplementary")
        }
        if request.minimumQueryCoverage != 0.5 {
            argv += ["--min-query-cover", String(request.minimumQueryCoverage)]
        }
        if request.replaceExisting {
            argv.append("--replace")
        }
        return argv
    }

    private static func copiedBundleBaseArgv(
        subcommand: String,
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        outputTrackName: String,
        outputTrackID: String?
    ) -> [String] {
        var argv = [
            CLICommandIdentity.executableName,
            "bam",
            subcommand,
            "--bundle",
            sourceBundleURL.path,
            "--mapping-result",
            mappingResultURL.path,
            "--output-bundle",
            outputBundleURL.path,
            "--output-track-name",
            outputTrackName,
        ]
        if let outputTrackID = trimmedOutputTrackID(outputTrackID) {
            argv += ["--output-track-id", outputTrackID]
        }
        return argv
    }

    private static func mappedReadsExplicitOptions(
        request: MappedReadsAnnotationRequest,
        bundleURL: URL,
        outputTrackName: String
    ) -> [String: ParameterValue] {
        var explicit: [String: ParameterValue] = [
            "bundlePath": .file(bundleURL),
            "sourceTrackID": .string(request.sourceTrackID),
            "outputTrackName": .string(outputTrackName),
        ]
        if let outputTrackID = trimmedOutputTrackID(request.outputTrackID) {
            explicit["outputTrackID"] = .string(outputTrackID)
        }
        return explicit
    }

    private static func copiedBundleExplicitOptions(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        outputTrackName: String,
        outputTrackID: String?
    ) -> [String: ParameterValue] {
        var explicit: [String: ParameterValue] = [
            "sourceBundlePath": .file(sourceBundleURL),
            "mappingResultPath": .file(mappingResultURL),
            "outputBundlePath": .file(outputBundleURL),
            "outputTrackName": .string(outputTrackName),
        ]
        if let outputTrackID = trimmedOutputTrackID(outputTrackID) {
            explicit["outputTrackID"] = .string(outputTrackID)
        }
        return explicit
    }

    private static func mappedReadsResolvedOptions(
        request: MappedReadsAnnotationRequest,
        sourceTrack: AlignmentTrackInfo,
        sourceAlignmentPath: String,
        sourceIndexPath: String?,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String
    ) -> [String: ParameterValue] {
        var resolved: [String: ParameterValue] = [
            "sourceTrackID": .string(request.sourceTrackID),
            "sourceTrackName": .string(sourceTrack.name),
            "sourceAlignmentPath": .file(URL(fileURLWithPath: sourceAlignmentPath)),
            "outputTrackID": .string(outputTrackID),
            "outputTrackName": .string(outputTrackName),
            "databasePath": .string(relativeDatabasePath),
            "primaryOnly": .boolean(request.primaryOnly),
            "includeSequence": .boolean(request.includeSequence),
            "includeQualities": .boolean(request.includeQualities),
            "replaceExisting": .boolean(request.replaceExisting),
        ]
        if let sourceIndexPath {
            resolved["sourceIndexPath"] = .file(URL(fileURLWithPath: sourceIndexPath))
        }
        return resolved
    }

    private static func bestMappedReadsResolvedOptions(
        request: BestMappedReadsAnnotationRequest,
        sourceBundleURL: URL,
        outputBundleURL: URL,
        mappingResult: MappingResult,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String
    ) -> [String: ParameterValue] {
        copiedBundleResolvedOptions(
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            outputBundleURL: outputBundleURL,
            mappingResult: mappingResult,
            outputTrackID: outputTrackID,
            outputTrackName: outputTrackName,
            relativeDatabasePath: relativeDatabasePath,
            selectionStrategy: "best_overlapping_interval_by_nm",
            additional: [
                "primaryOnly": .boolean(request.primaryOnly),
                "replaceExisting": .boolean(request.replaceExisting),
            ]
        )
    }

    private static func cdsBestResolvedOptions(
        request: CDSBestAnnotationRequest,
        sourceBundleURL: URL,
        outputBundleURL: URL,
        mappingResult: MappingResult,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String
    ) -> [String: ParameterValue] {
        copiedBundleResolvedOptions(
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            outputBundleURL: outputBundleURL,
            mappingResult: mappingResult,
            outputTrackID: outputTrackID,
            outputTrackName: outputTrackName,
            relativeDatabasePath: relativeDatabasePath,
            selectionStrategy: "best_cds_model_by_nm_and_query_coverage",
            additional: [
                "includeSecondary": .boolean(request.includeSecondary),
                "includeSupplementary": .boolean(request.includeSupplementary),
                "minimumQueryCoverage": .number(request.minimumQueryCoverage),
                "replaceExisting": .boolean(request.replaceExisting),
            ]
        )
    }

    private static func copiedBundleResolvedOptions(
        sourceBundleURL: URL,
        mappingResultURL: URL,
        outputBundleURL: URL,
        mappingResult: MappingResult,
        outputTrackID: String,
        outputTrackName: String,
        relativeDatabasePath: String,
        selectionStrategy: String,
        additional: [String: ParameterValue]
    ) -> [String: ParameterValue] {
        var resolved: [String: ParameterValue] = [
            "sourceBundlePath": .file(sourceBundleURL),
            "mappingResultPath": .file(mappingResultURL),
            "outputBundlePath": .file(outputBundleURL),
            "mappingBAMPath": .file(mappingResult.bamURL),
            "mappingBAIPath": .file(mappingResult.baiURL),
            "mappingTool": .string(mappingResult.mapper.rawValue),
            "mappingModeID": .string(mappingResult.modeID),
            "mappingTotalReads": .integer(mappingResult.totalReads),
            "mappingMappedReads": .integer(mappingResult.mappedReads),
            "mappingUnmappedReads": .integer(mappingResult.unmappedReads),
            "outputTrackID": .string(outputTrackID),
            "outputTrackName": .string(outputTrackName),
            "databasePath": .string(relativeDatabasePath),
            "selectionStrategy": .string(selectionStrategy),
        ]
        for (key, value) in additional {
            resolved[key] = value
        }
        return resolved
    }

    private static func trimmedOutputTrackID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
