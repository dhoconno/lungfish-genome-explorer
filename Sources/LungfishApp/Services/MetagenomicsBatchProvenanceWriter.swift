// MetagenomicsBatchProvenanceWriter.swift - Root provenance rollups for batch metagenomics results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

enum MetagenomicsBatchProvenanceWriter {
    @discardableResult
    static func ensureEsVirituBatchProvenanceIfPossible(batchRoot: URL) -> URL? {
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
            try? MetagenomicsBatchResultStore.saveEsViritu(inferred, to: root)
        }

        return try? writeEsVirituBatchProvenance(
            batchRoot: root,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: root.appendingPathComponent("esviritu.sqlite"),
            command: ["lungfish", "esviritu", "detect"]
        )
    }

    @discardableResult
    static func ensureTaxTriageProvenanceIfPossible(resultDirectory: URL) -> URL? {
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
            return try? writeAugmentedTaxTriageProvenance(
                existing: existing,
                result: result,
                sqliteURL: sqliteURL
            )
        }

        return try? writeTaxTriageProvenance(
            result: result,
            sqliteURL: sqliteURL,
            command: taxTriageCommand(for: result.config)
        )
    }

    @discardableResult
    static func writeEsVirituBatchProvenance(
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
        let batchStep = ProvenanceStep(
            toolName: "Lungfish EsViritu Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: command,
            inputs: batchInputs,
            outputs: batchOutputs,
            exitStatus: 0,
            wallTimeSeconds: sampleEnvelopes.compactMap(\.wallTimeSeconds).reduce(0, +),
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
            options: ProvenanceOptions(
                explicit: [
                    "sampleCount": .integer(manifest.header.sampleCount),
                    "successfulSamples": .integer(manifest.samples.count),
                    "summaryTSV": .string(manifest.summaryTSV),
                ]
            ),
            runtimeIdentity: sampleEnvelopes.first?.runtimeIdentity ?? ProvenanceRuntimeIdentity(),
            files: files,
            output: batchOutputs.first ?? childOutputs.first,
            outputs: uniqueDescriptors(batchOutputs + childOutputs),
            steps: childSteps + [batchStep],
            wallTimeSeconds: batchStep.wallTimeSeconds,
            exitStatus: 0,
            stderr: ""
        )

        return try ProvenanceWriter().write(envelope, to: batchRoot)
    }

    @discardableResult
    static func writeTaxTriageProvenance(
        result: TaxTriageResult,
        sqliteURL: URL?,
        command: [String]
    ) throws -> URL {
        let inputs = result.config.samples.flatMap(taxTriageInputDescriptors(for:))
        let outputs = taxTriageOutputDescriptors(result: result, sqliteURL: sqliteURL)
        let step = ProvenanceStep(
            toolName: "TaxTriage",
            toolVersion: result.config.revision,
            argv: command,
            inputs: inputs,
            outputs: outputs,
            exitStatus: Int(result.exitCode),
            wallTimeSeconds: result.runtime,
            stderr: ""
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(),
            workflowName: "TaxTriage",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "TaxTriage",
            toolVersion: result.config.revision,
            tool: ProvenanceToolIdentity(
                name: "TaxTriage",
                version: result.config.revision,
                kind: "nextflow"
            ),
            argv: command,
            options: taxTriageOptions(for: result.config),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: uniqueDescriptors(inputs + outputs),
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: result.runtime,
            exitStatus: Int(result.exitCode),
            stderr: ""
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

        for url in result.allOutputFiles {
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
        if let databasePath = config.kraken2DatabasePath {
            explicit["kraken2DatabasePath"] = .string(databasePath.path)
        }
        return ProvenanceOptions(explicit: explicit)
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
