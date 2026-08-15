// MetagenomicsBatchProvenanceWriter.swift - Root provenance rollups for batch metagenomics results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public enum MetagenomicsBatchProvenanceWriterError: Error, LocalizedError, Sendable, Equatable {
    case missingClassificationSampleProvenance(sampleId: String, directory: String)

    public var errorDescription: String? {
        switch self {
        case .missingClassificationSampleProvenance(let sampleId, let directory):
            return "Classification batch provenance is incomplete: sample \(sampleId) has no provenance sidecar in \(directory)"
        }
    }
}

/// Execution context that remains available even when no sample reaches the
/// point of writing a sample-level result or provenance sidecar.
public struct ClassificationBatchProvenanceContext: Sendable, Equatable {
    public let configurations: [ClassificationConfig]
    public let startedAt: Date
    public let completedAt: Date

    public init(
        configurations: [ClassificationConfig],
        startedAt: Date,
        completedAt: Date
    ) {
        self.configurations = configurations
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var wallTimeSeconds: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }
}

public enum MetagenomicsBatchProvenanceWriter {
    @discardableResult
    public static func ensureEsVirituBatchProvenanceIfPossible(batchRoot: URL) throws -> URL? {
        let root = batchRoot.standardizedFileURL
        guard isDirectory(root),
              root.lastPathComponent.hasPrefix("esviritu") else {
            return nil
        }

        let sidecarURL = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            return sidecarURL
        }

        let summaryURL = root.appendingPathComponent("esviritu-batch-summary.tsv")
        let manifest: EsVirituBatchResultManifest
        if let existingManifest = MetagenomicsBatchResultStore.loadEsViritu(from: root) {
            manifest = existingManifest
            try? writeSummaryIfMissing(summaryURL: summaryURL, samples: existingManifest.samples)
        } else {
            guard let inferred = inferEsVirituManifest(from: root, summaryURL: summaryURL) else {
                return nil
            }
            manifest = inferred
            try MetagenomicsBatchResultStore.saveEsViritu(inferred, to: root)
        }

        return try writeEsVirituBatchProvenance(
            batchRoot: root,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: root.appendingPathComponent("esviritu.sqlite"),
            command: [CLICommandIdentity.executableName, "esviritu", "detect"]
        )
    }

    @discardableResult
    public static func ensureTaxTriageProvenanceIfPossible(resultDirectory: URL) throws -> URL? {
        let root = resultDirectory.standardizedFileURL
        guard isDirectory(root),
              let result = try? TaxTriageResult.load(from: root) else {
            return nil
        }

        let sidecarURL = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let sqliteURL = root.appendingPathComponent("taxtriage.sqlite")
        if FileManager.default.fileExists(atPath: sidecarURL.path),
           let existing = ProvenanceRecorder.loadEnvelope(from: root) {
            let supplementalOutputs = taxTriageOutputDescriptors(result: result, sqliteURL: sqliteURL)
            let missingOutput = supplementalOutputs.contains { supplemental in
                !existing.outputs.contains { $0.path == supplemental.path }
            }
            let sqliteNeedsIndexStep = FileManager.default.fileExists(atPath: sqliteURL.path)
                && !existing.steps.contains { step in
                    step.outputs.contains { $0.path == sqliteURL.path }
                }
            if !missingOutput && !sqliteNeedsIndexStep {
                return sidecarURL
            }
            return try writeAugmentedTaxTriageProvenance(
                existing: existing,
                result: result,
                sqliteURL: sqliteURL
            )
        }

        return try writeTaxTriageProvenance(
            result: result,
            sqliteURL: sqliteURL,
            command: taxTriageCommand(for: result.config)
        )
    }

    @discardableResult
    public static func writeEsVirituBatchProvenance(
        batchRoot: URL,
        manifest: EsVirituBatchResultManifest,
        summaryURL: URL,
        sqliteURL: URL?,
        command: [String]
    ) throws -> URL {
        let sampleEnvelopes = manifest.samples.compactMap { sample -> ProvenanceEnvelope? in
            let sampleDirectory = resolvedURL(for: sample.resultDirectory, relativeTo: batchRoot)
            return ProvenanceRecorder.loadEnvelope(from: sampleDirectory)
        }

        let childSteps = sampleEnvelopes.flatMap(\.steps)
        let childFiles = sampleEnvelopes.flatMap(\.files)
        let childOutputs = uniqueDescriptors(
            sampleEnvelopes.flatMap(\.outputs) + sampleEnvelopes.compactMap(\.output)
        )
        let batchInputs = inputDescriptors(from: manifest)
        let batchOutputs = outputDescriptors(summaryURL: summaryURL, sqliteURL: sqliteURL)
        let stderr = usefulStderr(
            sampleEnvelopes.compactMap(\.stderr) + childSteps.compactMap(\.stderr)
        )
        let batchStep = ProvenanceStep(
            toolName: "Lungfish EsViritu Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: command,
            inputs: batchInputs,
            outputs: batchOutputs,
            exitStatus: 0,
            wallTimeSeconds: sampleEnvelopes.compactMap(\.wallTimeSeconds).reduce(0, +),
            stderr: stderr,
            dependsOn: childSteps.map(\.id),
            startedAt: sampleEnvelopes.map(\.createdAt).min() ?? manifest.header.createdAt,
            completedAt: Date()
        )

        let files = uniqueDescriptors(batchInputs + childFiles + batchOutputs)
        let envelope = ProvenanceEnvelope(
            createdAt: manifest.header.createdAt,
            workflowName: "EsViritu Batch",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish EsViritu Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "Lungfish EsViritu Batch",
                version: WorkflowRun.currentAppVersion,
                kind: "app"
            ),
            argv: command,
            options: esVirituBatchOptions(manifest: manifest, summaryURL: summaryURL, sqliteURL: sqliteURL),
            runtimeIdentity: sampleEnvelopes.first?.runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: files,
            output: batchOutputs.first ?? childOutputs.first,
            outputs: uniqueDescriptors(batchOutputs + childOutputs),
            steps: childSteps + [batchStep],
            wallTimeSeconds: batchStep.wallTimeSeconds,
            exitStatus: 0,
            stderr: stderr ?? ""
        )

        return try ProvenanceWriter().write(envelope, to: batchRoot)
    }

    /// Writes one batch-root envelope without flattening away the exact
    /// Kraken2/Bracken child invocations. Every returned sample must already
    /// have its sample-level provenance; a partial rollup is a blocking defect.
    @discardableResult
    public static func writeClassificationBatchProvenance(
        batchRoot: URL,
        manifest: ClassificationBatchResultManifest,
        summaryURL: URL,
        sqliteURL: URL?,
        command: [String],
        additionalStderr: [String] = [],
        additionalInputURLs: [URL] = [],
        additionalSampleDirectories: [URL] = [],
        context: ClassificationBatchProvenanceContext? = nil
    ) throws -> URL {
        // `lungfish-cli build-db kraken2` writes its own envelope at the batch
        // root. Capture it before the final rollup replaces that sidecar.
        let buildDatabaseEnvelope = classificationBuildDatabaseEnvelope(from: batchRoot)
        let returnedSampleDirectories = manifest.samples.map { sample in
            resolvedURL(for: sample.resultDirectory, relativeTo: batchRoot).standardizedFileURL
        }
        let returnedSampleDirectoryPaths = Set(returnedSampleDirectories.map(\.path))
        let returnedSampleEnvelopes = try zip(manifest.samples, returnedSampleDirectories).map {
            sample, sampleDirectory -> ProvenanceEnvelope in
            guard let envelope = ProvenanceRecorder.loadEnvelope(from: sampleDirectory) else {
                throw MetagenomicsBatchProvenanceWriterError.missingClassificationSampleProvenance(
                    sampleId: sample.sampleId,
                    directory: sampleDirectory.path
                )
            }
            return envelope
        }
        let failedSampleEnvelopes = uniqueURLs(additionalSampleDirectories)
            .filter { !returnedSampleDirectoryPaths.contains($0.path) }
            .compactMap { ProvenanceRecorder.loadEnvelope(from: $0) }
        let sampleEnvelopes = returnedSampleEnvelopes + failedSampleEnvelopes
        let rolledUpEnvelopes = sampleEnvelopes + (buildDatabaseEnvelope.map { [$0] } ?? [])

        let childSteps = sampleEnvelopes.flatMap(\.steps)
            + (buildDatabaseEnvelope.map(classificationBuildDatabaseSteps) ?? [])
        let childFiles = rolledUpEnvelopes.flatMap(\.files)
        let childOutputs = uniqueDescriptors(
            rolledUpEnvelopes.flatMap(\.outputs) + rolledUpEnvelopes.compactMap(\.output)
        )
        let batchInputs = classificationInputDescriptors(
            from: manifest,
            additionalInputURLs: additionalInputURLs,
            context: context
        )
        let batchOutputs = classificationOutputDescriptors(
            batchRoot: batchRoot,
            summaryURL: summaryURL,
            sqliteURL: sqliteURL
        )
        let stderr = usefulStderr(
            additionalStderr
                + manifest.samples.compactMap(\.message)
                + rolledUpEnvelopes.compactMap(\.stderr)
                + childSteps.compactMap(\.stderr)
        )
        let wallTime = context?.wallTimeSeconds
            ?? rolledUpEnvelopes.compactMap(\.wallTimeSeconds).reduce(0, +)
        let childExitStatus = rolledUpEnvelopes.compactMap(\.exitStatus).first(where: { $0 != 0 })
            ?? childSteps.compactMap(\.exitStatus).first(where: { $0 != 0 })
        let hasDegradationOrFailure = (manifest.degradedCount ?? 0) > 0
            || (manifest.failedCount ?? 0) > 0
            || !additionalStderr.isEmpty
        let exitStatus = childExitStatus ?? (hasDegradationOrFailure ? 1 : 0)
        let batchRuntimeIdentity = ProvenanceRuntimeIdentity()
        let batchStep = ProvenanceStep(
            toolName: "Lungfish Classification Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: command,
            resolvedOptions: classificationBatchResolvedOptions(
                manifest: manifest,
                sampleEnvelopes: sampleEnvelopes,
                context: context
            ),
            runtimeIdentity: batchRuntimeIdentity,
            inputs: uniqueDescriptors(batchInputs + childOutputs),
            outputs: batchOutputs,
            exitStatus: exitStatus,
            wallTimeSeconds: wallTime,
            stderr: stderr ?? "",
            dependsOn: childSteps.map(\.id),
            startedAt: context?.startedAt
                ?? rolledUpEnvelopes.map(\.createdAt).min()
                ?? manifest.header.createdAt,
            completedAt: context?.completedAt ?? Date()
        )

        let envelope = ProvenanceEnvelope(
            createdAt: context?.startedAt ?? manifest.header.createdAt,
            workflowName: "Classification Batch",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Classification Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "Lungfish Classification Batch",
                version: WorkflowRun.currentAppVersion,
                kind: "app"
            ),
            argv: command,
            options: classificationBatchOptions(
                manifest: manifest,
                summaryURL: summaryURL,
                sqliteURL: sqliteURL,
                sampleEnvelopes: sampleEnvelopes,
                buildDatabaseEnvelope: buildDatabaseEnvelope,
                context: context
            ),
            runtimeIdentity: batchRuntimeIdentity,
            files: uniqueDescriptors(batchInputs + childFiles + batchOutputs),
            output: batchOutputs.first ?? childOutputs.first,
            outputs: uniqueDescriptors(batchOutputs + childOutputs),
            steps: childSteps + [batchStep],
            wallTimeSeconds: wallTime,
            exitStatus: exitStatus,
            stderr: stderr ?? ""
        )

        return try ProvenanceWriter().write(envelope, to: batchRoot)
    }

    @discardableResult
    public static func writeTaxTriageProvenance(
        result: TaxTriageResult,
        sqliteURL: URL?,
        command: [String]
    ) throws -> URL {
        let inputs = result.config.samples.flatMap(taxTriageInputDescriptors(for:))
        let outputs = taxTriageOutputDescriptors(result: result, sqliteURL: sqliteURL)
        let stderr = taxTriageUsefulStderr(result: result)
        let step = ProvenanceStep(
            toolName: "TaxTriage",
            toolVersion: result.config.revision,
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: result.config.revision),
            argv: command,
            inputs: inputs,
            outputs: outputs,
            exitStatus: Int(result.exitCode),
            wallTimeSeconds: result.runtime,
            stderr: stderr ?? ""
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(),
            workflowName: "TaxTriage",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "TaxTriage",
            toolVersion: result.config.revision,
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: result.config.revision),
            tool: ProvenanceToolIdentity(
                name: "TaxTriage",
                version: result.config.revision,
                kind: "nextflow"
            ),
            argv: command,
            options: taxTriageOptions(for: result.config),
            runtimeIdentity: taxTriageRuntimeIdentity(),
            files: uniqueDescriptors(inputs + outputs),
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: result.runtime,
            exitStatus: Int(result.exitCode),
            stderr: stderr ?? ""
        )

        return try ProvenanceWriter().write(envelope, to: result.outputDirectory)
    }

    @discardableResult
    private static func writeAugmentedTaxTriageProvenance(
        existing: ProvenanceEnvelope,
        result: TaxTriageResult,
        sqliteURL: URL
    ) throws -> URL {
        let supplementalOutputs = taxTriageOutputDescriptors(result: result, sqliteURL: sqliteURL)
        var steps = existing.steps
        if FileManager.default.fileExists(atPath: sqliteURL.path),
           !steps.contains(where: { $0.outputs.contains { $0.path == sqliteURL.path } }) {
            let sqliteOutput = descriptor(forURL: sqliteURL, format: .unknown, role: .output)
            let indexInputs = supplementalOutputs.filter { $0.path != sqliteURL.path }
            steps.append(
                ProvenanceStep(
                    toolName: "Lungfish TaxTriage Index",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: [
                        "lungfish-app",
                        "taxtriage",
                        "index",
                        "--input",
                        result.outputDirectory.path,
                        "--output",
                        sqliteURL.path,
                    ],
                    inputs: indexInputs,
                    outputs: [sqliteOutput],
                    exitStatus: 0,
                    wallTimeSeconds: 0,
                    stderr: "",
                    dependsOn: existing.steps.map(\.id),
                    completedAt: Date()
                )
            )
        }

        let files = uniqueDescriptors(
            existing.files
                + result.config.samples.flatMap(taxTriageInputDescriptors(for:))
                + supplementalOutputs
        )
        let outputs = uniqueDescriptors(existing.outputs + supplementalOutputs)
        let output = existing.output ?? outputs.first
        let envelope = ProvenanceEnvelope(
            schemaVersion: existing.schemaVersion,
            id: existing.id,
            createdAt: existing.createdAt,
            workflowName: existing.workflowName,
            workflowVersion: existing.workflowVersion,
            toolName: existing.toolName,
            toolVersion: existing.toolVersion,
            githubReleaseVersion: existing.githubReleaseVersion,
            tool: existing.tool,
            argv: existing.argv,
            reproducibleCommand: existing.reproducibleCommand,
            options: existing.options,
            runtimeIdentity: existing.runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: existing.wallTimeSeconds ?? result.runtime,
            exitStatus: existing.exitStatus ?? Int(result.exitCode),
            stderr: existing.stderr,
            signatures: [],
            legacyWorkflowRun: existing.legacyRun
        )

        return try ProvenanceWriter().write(envelope, to: result.outputDirectory)
    }

    private static func inferEsVirituManifest(
        from batchRoot: URL,
        summaryURL: URL
    ) -> EsVirituBatchResultManifest? {
        guard let sampleDirectories = try? FileManager.default.contentsOfDirectory(
            at: batchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var records: [MetagenomicsBatchSampleRecord] = []
        var createdAt: Date?
        for directory in sampleDirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isDirectory(directory),
                  let envelope = ProvenanceRecorder.loadEnvelope(from: directory) else {
                continue
            }
            let inputFiles = uniqueStrings(
                (envelope.files + envelope.steps.flatMap(\.inputs))
                    .filter { $0.role == .input }
                    .map(\.path)
            )
            records.append(
                MetagenomicsBatchSampleRecord(
                    sampleId: directory.lastPathComponent,
                    resultDirectory: appRelativePath(from: batchRoot, to: directory),
                    inputFiles: inputFiles,
                    isPairedEnd: inputFiles.count == 2
                )
            )
            createdAt = minDate(createdAt, envelope.createdAt)
        }

        guard !records.isEmpty else { return nil }
        try? writeSummaryIfMissing(summaryURL: summaryURL, samples: records)
        return EsVirituBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 1,
                createdAt: createdAt ?? Date(),
                sampleCount: records.count
            ),
            summaryTSV: summaryURL.lastPathComponent,
            samples: records
        )
    }

    private static func writeSummaryIfMissing(
        summaryURL: URL,
        samples: [MetagenomicsBatchSampleRecord]
    ) throws {
        guard !FileManager.default.fileExists(atPath: summaryURL.path) else { return }
        var lines = ["sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror"]
        lines += samples.map { sample in
            [
                tsvField(sample.sampleId),
                "ok",
                "",
                "",
                "",
                "",
            ].joined(separator: "\t")
        }
        try lines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    private static func inputDescriptors(
        from manifest: EsVirituBatchResultManifest
    ) -> [ProvenanceFileDescriptor] {
        uniqueDescriptors(
            manifest.samples
                .flatMap(\.inputFiles)
                .map { descriptor(forPath: $0, role: .input) }
        )
    }

    private static func classificationInputDescriptors(
        from manifest: ClassificationBatchResultManifest,
        additionalInputURLs: [URL] = [],
        context: ClassificationBatchProvenanceContext? = nil
    ) -> [ProvenanceFileDescriptor] {
        let manifestInputURLs = manifest.samples
            .flatMap(\.inputFiles)
            .map { URL(fileURLWithPath: $0) }
        let contextInputURLs = context?.configurations.flatMap { config in
            config.originalInputFiles ?? config.inputFiles
        } ?? []
        return uniqueDescriptors(
            uniqueURLs(manifestInputURLs + additionalInputURLs + contextInputURLs)
                .map { url in
                    ProvenanceFileDescriptor(
                        fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(url: url, role: .input)
                    )
                }
        )
    }

    private static func classificationBuildDatabaseEnvelope(
        from batchRoot: URL
    ) -> ProvenanceEnvelope? {
        guard let envelope = ProvenanceRecorder.loadEnvelope(from: batchRoot) else {
            return nil
        }
        let expectedName = "lungfish build-db kraken2"
        let hasExpectedName = envelope.workflowName.lowercased() == expectedName
            || envelope.toolName.lowercased() == expectedName
        let normalizedArgv = envelope.argv.map { $0.lowercased() }
        let hasExpectedArgv = normalizedArgv.indices.contains { index in
            normalizedArgv[index] == "build-db"
                && normalizedArgv.indices.contains(index + 1)
                && normalizedArgv[index + 1] == "kraken2"
        }
        return hasExpectedName || hasExpectedArgv ? envelope : nil
    }

    private static func classificationBuildDatabaseSteps(
        from envelope: ProvenanceEnvelope
    ) -> [ProvenanceStep] {
        guard !envelope.steps.isEmpty else { return [] }
        let terminalIndex = envelope.steps.lastIndex {
            $0.argv == envelope.argv || $0.toolName == envelope.toolName
        } ?? envelope.steps.index(before: envelope.steps.endIndex)
        var effectiveOptions = envelope.options.defaults
        effectiveOptions.merge(envelope.options.explicit) { _, explicit in explicit }
        effectiveOptions.merge(envelope.options.resolvedDefaults) { _, resolved in resolved }

        return envelope.steps.enumerated().map { index, step in
            guard index == terminalIndex else { return step }
            var resolvedOptions = effectiveOptions
            resolvedOptions.merge(step.resolvedOptions) { _, stepValue in stepValue }
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: step.runtimeIdentity ?? envelope.runtimeIdentity,
                inputs: step.inputs,
                outputs: step.outputs,
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }

    private static func structuredBuildDatabaseOptions(
        from envelope: ProvenanceEnvelope
    ) -> ParameterValue {
        .dictionary([
            "explicit": .dictionary(envelope.options.explicit),
            "defaults": .dictionary(envelope.options.defaults),
            "resolvedDefaults": .dictionary(envelope.options.resolvedDefaults),
        ])
    }

    private static func classificationOutputDescriptors(
        batchRoot: URL,
        summaryURL: URL,
        sqliteURL: URL?
    ) -> [ProvenanceFileDescriptor] {
        let manifestURL = batchRoot.appendingPathComponent(ClassificationBatchResultManifest.filename)
        var outputs = [
            descriptorForFileOrDirectory(url: summaryURL, format: .text, role: .report),
            descriptorForFileOrDirectory(url: manifestURL, format: .json, role: .output),
        ]
        if let sqliteURL, FileManager.default.fileExists(atPath: sqliteURL.path) {
            outputs.append(
                descriptorForFileOrDirectory(url: sqliteURL, format: .unknown, role: .output)
            )
        }
        return uniqueDescriptors(outputs)
    }

    private static func classificationBatchOptions(
        manifest: ClassificationBatchResultManifest,
        summaryURL: URL,
        sqliteURL: URL?,
        sampleEnvelopes: [ProvenanceEnvelope],
        buildDatabaseEnvelope: ProvenanceEnvelope?,
        context: ClassificationBatchProvenanceContext?
    ) -> ProvenanceOptions {
        let completedCount = manifest.completedCount
            ?? manifest.samples.filter { ($0.status ?? "ok") == "ok" }.count
        let degradedCount = manifest.degradedCount
            ?? manifest.samples.filter { $0.status == "degraded" }.count
        let failedCount = manifest.failedCount ?? max(
            0,
            manifest.header.sampleCount - completedCount - degradedCount
        )
        var resolvedDefaults: [String: ParameterValue] = classificationBatchResolvedOptions(
            manifest: manifest,
            sampleEnvelopes: sampleEnvelopes,
            context: context
        )
        resolvedDefaults["summaryTSV"] = .string(summaryURL.path)
        resolvedDefaults["manifestPath"] = .string(
            summaryURL.deletingLastPathComponent()
                .appendingPathComponent(ClassificationBatchResultManifest.filename).path
        )
        if let sqliteURL, FileManager.default.fileExists(atPath: sqliteURL.path) {
            resolvedDefaults["sqlitePath"] = .string(sqliteURL.path)
        }
        if let buildDatabaseEnvelope {
            resolvedDefaults["buildDatabaseOptions"] = structuredBuildDatabaseOptions(
                from: buildDatabaseEnvelope
            )
        }

        var explicit: [String: ParameterValue] = [
            "goal": .string(manifest.goal),
            "databaseName": .string(manifest.databaseName),
            "databaseVersion": .string(manifest.databaseVersion),
            "sampleCount": .integer(manifest.header.sampleCount),
            "returnedSampleCount": .integer(manifest.samples.count),
            "completedCount": .integer(completedCount),
            "degradedCount": .integer(degradedCount),
            "failedCount": .integer(failedCount),
            "pairedEndSamples": .integer(manifest.samples.filter(\.isPairedEnd).count),
            "manifestSummaryTSV": .string(manifest.summaryTSV),
        ]
        var defaults: [String: ParameterValue] = [
            "summaryFilename": .string("classification-batch-summary.tsv"),
            "sqliteFilename": .string("kraken2.sqlite"),
            "manifestFilename": .string(ClassificationBatchResultManifest.filename),
        ]
        if let contextOptions = classificationContextOptions(context) {
            explicit.merge(contextOptions.explicit) { _, contextValue in contextValue }
            defaults.merge(contextOptions.defaults) { _, contextValue in contextValue }
            resolvedDefaults.merge(contextOptions.resolvedDefaults) { _, contextValue in contextValue }
        }

        return ProvenanceOptions(
            explicit: explicit,
            defaults: defaults,
            resolvedDefaults: resolvedDefaults
        )
    }

    private static func classificationBatchResolvedOptions(
        manifest: ClassificationBatchResultManifest,
        sampleEnvelopes: [ProvenanceEnvelope],
        context: ClassificationBatchProvenanceContext? = nil
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "goal": .string(manifest.goal),
            "databaseName": .string(manifest.databaseName),
            "databaseVersion": .string(manifest.databaseVersion),
            "completedCount": .integer(
                manifest.completedCount
                    ?? manifest.samples.filter { ($0.status ?? "ok") == "ok" }.count
            ),
            "degradedCount": .integer(
                manifest.degradedCount
                    ?? manifest.samples.filter { $0.status == "degraded" }.count
            ),
            "failedCount": .integer(
                manifest.failedCount
                    ?? max(0, manifest.header.sampleCount - manifest.samples.count)
            ),
        ]
        let contextResolutions = context?.configurations.compactMap { config -> BrackenProfileResolution? in
            guard config.goal == .profile else { return nil }
            return BrackenDatabaseCapabilities.resolve(
                catalogID: config.databaseCatalogID,
                installationRecipe: config.databaseInstallationRecipe,
                request: config.brackenProfileRequest ?? .automaticDefault
            )
        } ?? []
        let ranks = classificationOptionStrings(
            sampleEnvelopes: sampleEnvelopes,
            keys: ["brackenResolvedRank", "resolvedRank"]
        ) + contextResolutions.map(\.rank.code)
        options["resolvedProfileRanks"] = .array(
            uniqueStrings(ranks).sorted().map(ParameterValue.string)
        )

        let catalogIDs = classificationOptionStrings(
            sampleEnvelopes: sampleEnvelopes,
            keys: ["databaseCatalogID"]
        ) + (context?.configurations.compactMap(\.databaseCatalogID) ?? [])
        if !catalogIDs.isEmpty {
            options["databaseCatalogIDs"] = .array(
                uniqueStrings(catalogIDs).sorted().map(ParameterValue.string)
            )
        }
        let digests = classificationOptionStrings(
            sampleEnvelopes: sampleEnvelopes,
            keys: ["databaseDigest"]
        ) + (context?.configurations.compactMap(\.databaseDigest) ?? [])
        if !digests.isEmpty {
            options["databaseDigests"] = .array(
                uniqueStrings(digests).sorted().map(ParameterValue.string)
            )
        }
        let recipes = classificationOptionStrings(
            sampleEnvelopes: sampleEnvelopes,
            keys: ["databaseInstallationRecipe"]
        ) + (context?.configurations.compactMap { $0.databaseInstallationRecipe?.provenanceValue } ?? [])
        if !recipes.isEmpty {
            options["databaseInstallationRecipes"] = .array(
                uniqueStrings(recipes).sorted().map(ParameterValue.string)
            )
        }
        if let contextOptions = classificationContextOptions(context) {
            options.merge(contextOptions.resolvedDefaults) { _, contextValue in contextValue }
        }
        return options
    }

    private static func classificationContextOptions(
        _ context: ClassificationBatchProvenanceContext?
    ) -> ProvenanceOptions? {
        guard let config = context?.configurations.first else { return nil }
        var explicit: [String: ParameterValue] = [
            "goal": .string(config.goal.rawValue),
            "databaseName": .string(config.databaseName),
            "databaseVersion": .string(config.databaseVersion),
            "databasePath": .file(config.databasePath.standardizedFileURL),
            "databaseDigest": config.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": config.databaseCatalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": config.databaseInstallationRecipe
                .map { .string($0.provenanceValue) } ?? .null,
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "memoryMapping": .boolean(config.memoryMapping),
            "quickMode": .boolean(config.quickMode),
            "pairedEnd": .boolean(config.isPairedEnd),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
            "configurationCount": .integer(context?.configurations.count ?? 0),
        ]
        var defaults: [String: ParameterValue] = [:]
        var resolvedDefaults: [String: ParameterValue] = [
            "effectiveMemoryMapping": .boolean(config.memoryMapping),
        ]
        if config.goal == .profile {
            let request = config.brackenProfileRequest ?? .automaticDefault
            let resolution = BrackenDatabaseCapabilities.resolve(
                catalogID: config.databaseCatalogID,
                installationRecipe: config.databaseInstallationRecipe,
                request: request
            )
            explicit["brackenRankRequest"] = .string(request.rank.provenanceValue)
            explicit["brackenRequestedReadLength"] = .integer(request.readLength)
            explicit["brackenRequestedThreshold"] = .integer(request.threshold)
            defaults["brackenRankRequest"] = .string("automatic")
            defaults["brackenReadLength"] = .integer(150)
            defaults["brackenThreshold"] = .integer(10)
            resolvedDefaults["brackenResolvedRank"] = .string(resolution.rank.code)
            resolvedDefaults["brackenResolutionSource"] = .string(resolution.source.rawValue)
            resolvedDefaults["brackenReadLength"] = .integer(resolution.readLength)
            resolvedDefaults["brackenThreshold"] = .integer(resolution.threshold)
        }
        return ProvenanceOptions(
            explicit: explicit,
            defaults: defaults,
            resolvedDefaults: resolvedDefaults
        )
    }

    private static func classificationOptionStrings(
        sampleEnvelopes: [ProvenanceEnvelope],
        keys: Set<String>
    ) -> [String] {
        let envelopeValues = sampleEnvelopes.flatMap { envelope -> [String] in
            let dictionaries = [
                envelope.options.explicit,
                envelope.options.defaults,
                envelope.options.resolvedDefaults,
            ]
            return dictionaries.flatMap { dictionary in
                keys.compactMap { dictionary[$0]?.stringValue }
            }
        }
        let stepValues = sampleEnvelopes
            .flatMap(\.steps)
            .flatMap { step in keys.compactMap { step.resolvedOptions[$0]?.stringValue } }
        return uniqueStrings(envelopeValues + stepValues).sorted()
    }

    private static func outputDescriptors(
        summaryURL: URL,
        sqliteURL: URL?
    ) -> [ProvenanceFileDescriptor] {
        var outputs = [
            descriptor(forURL: summaryURL, format: .text, role: .report),
        ]
        if let sqliteURL, FileManager.default.fileExists(atPath: sqliteURL.path) {
            outputs.append(descriptor(forURL: sqliteURL, format: .unknown, role: .output))
        }
        return outputs
    }

    private static func esVirituBatchOptions(
        manifest: EsVirituBatchResultManifest,
        summaryURL: URL,
        sqliteURL: URL?
    ) -> ProvenanceOptions {
        var resolvedDefaults: [String: ParameterValue] = [
            "summaryTSV": .string(summaryURL.path),
            "summaryFilename": .string(summaryURL.lastPathComponent),
        ]
        if let sqliteURL {
            resolvedDefaults["sqlitePath"] = .string(sqliteURL.path)
            resolvedDefaults["sqliteFilename"] = .string(sqliteURL.lastPathComponent)
        }

        return ProvenanceOptions(
            explicit: [
                "sampleCount": .integer(manifest.header.sampleCount),
                "successfulSamples": .integer(manifest.samples.count),
                "manifestSummaryTSV": .string(manifest.summaryTSV),
                "pairedEndSamples": .integer(manifest.samples.filter(\.isPairedEnd).count),
            ],
            defaults: [
                "summaryFilename": .string("esviritu-batch-summary.tsv"),
                "sqliteFilename": .string("esviritu.sqlite"),
                "manifestFilename": .string(EsVirituBatchResultManifest.filename),
            ],
            resolvedDefaults: resolvedDefaults
        )
    }

    private static func taxTriageInputDescriptors(
        for sample: TaxTriageSample
    ) -> [ProvenanceFileDescriptor] {
        ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? []))
            .map { descriptor(forURL: $0, format: .fastq, role: .input) }
    }

    private static func taxTriageOutputDescriptors(
        result: TaxTriageResult,
        sqliteURL: URL?
    ) -> [ProvenanceFileDescriptor] {
        var outputs: [ProvenanceFileDescriptor] = []
        let resultSidecarURL = result.outputDirectory.appendingPathComponent("taxtriage-result.json")
        outputs.append(descriptor(forURL: resultSidecarURL, format: .json, role: .output))

        let reportPaths = Set((result.reportFiles + result.kronaFiles).map(\.standardizedFileURL.path))
        let logPaths = Set(([result.logFile, result.traceFile].compactMap(\.self)).map(\.standardizedFileURL.path))

        for url in TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(
            result.allOutputFiles,
            outputDirectory: result.outputDirectory
        ) {
            let standardizedPath = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: standardizedPath),
                  !isDirectory(url) else {
                continue
            }
            let role: FileRole = logPaths.contains(standardizedPath)
                ? .log
                : (reportPaths.contains(standardizedPath) ? .report : .output)
            outputs.append(descriptor(forURL: url, format: nil, role: role))
        }

        if let sqliteURL, FileManager.default.fileExists(atPath: sqliteURL.path) {
            outputs.append(descriptor(forURL: sqliteURL, format: .unknown, role: .output))
        }

        return uniqueDescriptors(outputs)
    }

    private static func taxTriageCommand(for config: TaxTriageConfig) -> [String] {
        var command = [
            "nextflow",
            "run",
            TaxTriageConfig.pipelineRepository,
            "-r",
            config.revision,
            "-profile",
            config.profile,
            "--input",
            config.samplesheetURL.path,
            "--outdir",
            config.outputDirectory.path,
        ]
        if let dbPath = config.kraken2DatabasePath {
            command += ["--db", dbPath.path]
        }
        command += [
            "--top_hits_count",
            String(config.topHitsCount),
            "--k2_confidence",
            String(config.k2Confidence),
            "--rank",
            config.rank,
        ]
        if config.skipAssembly {
            command.append("--skip_assembly")
        }
        if config.skipKrona {
            command.append("--skip_krona")
        }
        command += [
            "--max_memory",
            config.maxMemory,
            "--max_cpus",
            String(config.maxCpus),
        ]
        command += config.extraArguments
        return command
    }

    private static func taxTriageOptions(for config: TaxTriageConfig) -> ProvenanceOptions {
        var explicit: [String: ParameterValue] = [
            "sampleCount": .integer(config.samples.count),
            "samplesheet": .string(config.samplesheetURL.path),
            "outputDirectory": .string(config.outputDirectory.path),
            "platform": .string(config.platform.rawValue),
            "classifiers": .array(config.classifiers.map { .string($0) }),
            "topHitsCount": .integer(config.topHitsCount),
            "k2Confidence": .number(config.k2Confidence),
            "rank": .string(config.rank),
            "skipAssembly": .boolean(config.skipAssembly),
            "skipKrona": .boolean(config.skipKrona),
            "maxMemory": .string(config.maxMemory),
            "maxCpus": .integer(config.maxCpus),
            "profile": .string(config.profile),
            "revision": .string(config.revision),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
        ]
        if let githubReleaseVersion = TaxTriageConfig.githubReleaseVersion(for: config.revision) {
            explicit["github_release_version"] = .string(githubReleaseVersion)
        }
        if let databasePath = config.kraken2DatabasePath {
            explicit["kraken2DatabasePath"] = .string(databasePath.path)
        }
        if let containerRuntime = config.containerRuntime {
            explicit["containerRuntime"] = .string(containerRuntime)
        }
        if let sourceBundleURLs = config.sourceBundleURLs {
            explicit["sourceBundleURLs"] = .array(sourceBundleURLs.map { .string($0.path) })
        }

        var resolvedDefaults: [String: ParameterValue] = [
            "platform": .string(config.platform.rawValue),
            "classifiers": .array(config.classifiers.map { .string($0) }),
            "topHitsCount": .integer(config.topHitsCount),
            "k2Confidence": .number(config.k2Confidence),
            "rank": .string(config.rank),
            "skipAssembly": .boolean(config.skipAssembly),
            "skipKrona": .boolean(config.skipKrona),
            "maxMemory": .string(config.maxMemory),
            "maxCpus": .integer(config.maxCpus),
            "profile": .string(config.profile),
            "revision": .string(config.revision),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
        ]
        if let githubReleaseVersion = TaxTriageConfig.githubReleaseVersion(for: config.revision) {
            resolvedDefaults["github_release_version"] = .string(githubReleaseVersion)
        }

        return ProvenanceOptions(
            explicit: explicit,
            defaults: [
                "platform": .string(TaxTriageConfig.Platform.illumina.rawValue),
                "classifiers": .array([.string("kraken2")]),
                "topHitsCount": .integer(10),
                "k2Confidence": .number(0.2),
                "rank": .string("S"),
                "skipAssembly": .boolean(true),
                "skipKrona": .boolean(false),
                "maxMemory": .string("16.GB"),
                "profile": .string("docker"),
                "revision": .string(TaxTriageConfig.defaultRevision),
                "github_release_version": .string(TaxTriageConfig.defaultGithubReleaseVersion),
                "extraArgs": .string(""),
            ],
            resolvedDefaults: resolvedDefaults
        )
    }

    private static func taxTriageRuntimeIdentity() -> ProvenanceRuntimeIdentity {
        let environment = ProcessInfo.processInfo.environment
        return ProvenanceRuntimeIdentity(
            condaEnvironment: "nextflow",
            condaPrefix: environment["CONDA_PREFIX"]
        )
    }

    private static func taxTriageUsefulStderr(result: TaxTriageResult) -> String? {
        guard result.exitCode != 0 || result.hasIgnoredFailures || result.hasSampleFailures else {
            return ""
        }
        guard let logFile = result.logFile,
              let text = try? String(contentsOf: logFile, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).limitedForProvenance
    }

    private static func usefulStderr(_ values: [String]) -> String? {
        let stderr = uniqueStrings(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        .joined(separator: "\n")
        return stderr.isEmpty ? nil : stderr.limitedForProvenance
    }

    private static func descriptor(
        forPath path: String,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        descriptor(forURL: URL(fileURLWithPath: path), format: nil, role: role)
    }

    private static func descriptor(
        forURL url: URL,
        format: FileFormat?,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        if FileManager.default.fileExists(atPath: url.path),
           !isDirectory(url) {
            return ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
            )
        }
        return ProvenanceFileDescriptor(path: url.path, format: format, role: role)
    }

    private static func descriptorForFileOrDirectory(
        url: URL,
        format: FileFormat?,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(
                url: url,
                format: format,
                role: role
            )
        )
    }

    private static func resolvedURL(for path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return baseURL.appendingPathComponent(path)
    }

    private static func uniqueDescriptors(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var orderedKeys: [String] = []
        var byKey: [String: ProvenanceFileDescriptor] = [:]
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if byKey[key] == nil {
                orderedKeys.append(key)
            }
            byKey[key] = descriptor
        }
        return orderedKeys.compactMap { byKey[$0] }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        return urls.compactMap { url in
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else { return nil }
            return standardizedURL
        }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    private static func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private static func appRelativePath(from base: URL, to target: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        if targetPath.hasPrefix(normalizedBase) {
            return String(targetPath.dropFirst(normalizedBase.count))
        }
        return target.lastPathComponent
    }

    private static func tsvField(_ value: String) -> String {
        if value.contains("\t") || value.contains("\n") || value.contains("\"") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private extension String {
    var limitedForProvenance: String {
        let limit = 16_384
        guard count > limit else { return self }
        let end = index(startIndex, offsetBy: limit)
        return String(self[..<end]) + "\n[truncated]"
    }
}
