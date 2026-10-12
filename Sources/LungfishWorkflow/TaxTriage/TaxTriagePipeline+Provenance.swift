// TaxTriagePipeline+Provenance.swift - The provenance record a TaxTriage run saves for itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension TaxTriagePipeline {

    // MARK: - Provenance

    func saveTaxTriageProvenanceOrThrow(
        runID: UUID,
        outputDirectory: URL,
        description: String,
        exitCode: Int32,
        stderr: String,
        logFile: URL?
    ) async throws {
        do {
            // The run began with every option of its record, and the save puts each under its home.
            let parameters = await ProvenanceRecorder.shared.getRun(runID)?.parameters ?? [:]
            try await ProvenanceRecorder.shared.save(
                runID: runID,
                to: outputDirectory,
                options: TaxTriageRecordFacts.recordOptions(fromRunParameters: parameters)
            )
        } catch {
            let message = "Failed to save TaxTriage \(description) provenance: \(error.localizedDescription)"
            let combinedStderr = [stderr, message]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw TaxTriagePipelineError.pipelineFailed(
                exitCode: exitCode,
                stderr: combinedStderr,
                logFile: logFile
            )
        }
    }

    func taxTriagePersistenceFailure(
        artifactDescription: String,
        error: Error,
        logFile: URL?
    ) -> TaxTriagePipelineError {
        TaxTriagePipelineError.pipelineFailed(
            exitCode: -1,
            stderr: "Failed to save TaxTriage \(artifactDescription): \(error.localizedDescription)",
            logFile: logFile
        )
    }

    /// The parameters a TaxTriage run begins with, every option its record holds (``TaxTriageRecordFacts``).
    nonisolated func provenanceParameters(
        for config: TaxTriageConfig,
        interleavedSplits: [InterleavedSampleSplit] = []
    ) -> [String: ParameterValue] {
        TaxTriageRecordFacts(config: config, interleavedSplits: interleavedSplits).runParameters
    }

    /// Records the TaxTriage step. A run that ended 0 names its result among `outputFiles`, and each task failure
    /// that TaxTriage ignored in it adds a warning line to the step's stderr (T8). The step's resolved options hold the
    /// version of the Nextflow that ran, from the banner in the log among `outputFiles`.
    func recordTaxTriageProvenanceStep(
        runID: UUID,
        config: TaxTriageConfig,
        command: [String],
        outputFiles: [URL],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) async {
        let warnings = exitCode == 0 ? TaxTriageRecordFacts.ignoredFailureWarnings(inResultAmong: outputFiles) : []
        let stderrLines = ([stderr ?? ""] + warnings).filter { !$0.isEmpty }
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: TaxTriageRecordFacts.toolName,
            toolVersion: config.revision,
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: config.revision),
            command: command,
            resolvedOptions: TaxTriageRecordFacts.engineOptions(logAmong: outputFiles),
            inputs: inputRecords(for: config),
            outputs: outputRecords(for: outputFiles),
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr == nil && stderrLines.isEmpty ? nil : stderrLines.joined(separator: "\n")
        )
    }

    func inputRecords(for config: TaxTriageConfig) -> [FileRecord] {
        config.samples.flatMap { sample in
            ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? []))
                .map { url in
                    ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
                }
        }
    }

    func outputRecords(for urls: [URL]) -> [FileRecord] {
        urls
            .taxTriageUniquedByPath()
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
            .map { ProvenanceRecorder.fileRecord(url: $0, role: .output) }
    }
}

// MARK: - TaxTriageRecordFacts

/// The facts a TaxTriage record holds about one run, as values. The pipeline's own save writes them in 2.8, and the
/// executor's root record takes the same values when `taxtriage run` moves to it, so one writer puts them in each record
/// (Phase 2.8 lane B2, decisions T6 to T8 of `docs/plans/2026-10-11-phase-2-8.md`).
///
/// - Every TaxTriage step is the tool `taxtriage` at the revision, with the release tag beside it (RT4).
/// - The settings the run was asked for are explicit options.
/// - The plan of a record of one sample is the resolved default `readSetPlan`, the home decision E13 of Phase 2.7 names
///   (T7). A pooled record of several samples keeps its plans keyed by sample under `read_set_plans` in the explicit
///   options, the home released builds wrote, because one plan cannot hold several samples' plans.
/// - The Kraken 2 database is recorded as decision E9 of Phase 2.7 records EsViritu's, as resolved defaults.
/// - Each task failure TaxTriage ignored is one warning line (T8), and the run still ends `completed`.
///
/// The R1 and R2 halves of an interleaved file are scratch that the run removes, so no fact names one (T6). The record
/// names the durable interleaved file instead.
struct TaxTriageRecordFacts: Sendable, Equatable {
    /// The one tool name of a TaxTriage step, the name the batch record of a serial run already gives each sample.
    static let toolName = "taxtriage"
    /// The status of a TaxTriage database's identity. No digest pins it, and no database folder is hashed per run.
    static let databaseIdentityStatus = "unpinned"
    /// The workflow name of a database install receipt, the record an install writes into the database folder.
    static let databaseInstallWorkflowName = "metagenomics.database.install"
    /// The run parameters a record holds among its resolved defaults rather than its explicit options.
    static let resolvedDefaultKeys: Set<String> = [
        RecordedReadSetPlan.key, "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes",
        "databaseCatalogID", "databaseCatalogVersion",
    ]

    /// The settings the run was asked for.
    let explicitOptions: [String: ParameterValue]
    /// What the run resolved, the plan of a record of one sample and the identity of its database.
    let resolvedDefaults: [String: ParameterValue]

    init(config: TaxTriageConfig, interleavedSplits: [TaxTriagePipeline.InterleavedSampleSplit] = []) {
        var explicit: [String: ParameterValue] = [
            "workflow": .string("taxtriage"),
            "sample_count": .integer(config.samples.count),
            "platform": .string(config.platform.rawValue),
            "classifiers": .array(config.classifiers.map { .string($0) }),
            "top_hits_count": .integer(config.topHitsCount),
            "k2_confidence": .number(config.k2Confidence),
            "rank": .string(config.rank),
            "skip_assembly": .boolean(config.skipAssembly),
            "skip_krona": .boolean(config.skipKrona),
            "max_memory": .string(config.maxMemory),
            "max_cpus": .integer(config.maxCpus),
            "profile": .string(config.profile),
            "revision": .string(config.revision),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
            "output_directory": .file(config.outputDirectory),
            "remove_taxids": .string(config.effectiveRemoveTaxids ?? ""),
        ]
        if let githubReleaseVersion = TaxTriageConfig.githubReleaseVersion(for: config.revision) {
            explicit["github_release_version"] = .string(githubReleaseVersion)
        }
        if !interleavedSplits.isEmpty {
            explicit["interleaved_samples_split_to_r1_r2"] = .array(interleavedSplits.map { .string($0.sampleId) })
        }
        var resolved = Self.databaseIdentity(at: config.kraken2DatabasePath)
        if config.samples.count == 1 {
            if let plan = config.samples[0].readSetPlan?.provenanceParameters[RecordedReadSetPlan.key] {
                resolved[RecordedReadSetPlan.key] = plan
            }
        } else {
            explicit.merge(TaxTriagePipeline.readSetProvenanceParameters(for: config)) { current, _ in current }
        }
        explicitOptions = explicit
        resolvedDefaults = resolved
    }

    /// Every option of the record, the parameters a recorded run begins with. The recorder takes a record's resolved
    /// defaults only when it saves the run, so the save puts each under its home (``recordOptions(fromRunParameters:)``).
    var runParameters: [String: ParameterValue] {
        explicitOptions.merging(resolvedDefaults) { explicit, _ in explicit }
    }

    /// The options a save passes for a run that began with `parameters`, the resolved defaults among them. The
    /// recorder merges the other parameters into the explicit options and leaves out each one it records as a resolved
    /// default with the same value.
    static func recordOptions(fromRunParameters parameters: [String: ParameterValue]) -> ProvenanceOptions {
        ProvenanceOptions(resolvedDefaults: parameters.filter { resolvedDefaultKeys.contains($0.key) })
    }

    /// The identity of the Kraken 2 database at `databaseURL`, as decision E9 gives EsViritu's. Its path, the size of
    /// each core file and a status that says no digest pins it, plus the catalog entry and version when the folder's
    /// install receipt names the folder. Nothing is hashed. Empty when the run names no database.
    static func databaseIdentity(at databaseURL: URL?) -> [String: ParameterValue] {
        guard let databaseURL else { return [:] }
        let database = databaseURL.standardizedFileURL
        var sizes: [String: ParameterValue] = [:]
        for name in MetagenomicsDatabaseRegistry.requiredKraken2Files {
            let values = try? database.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                sizes[name] = .integer(size)
            }
        }
        var identity: [String: ParameterValue] = [
            "databasePath": .string(database.path),
            "databaseIdentityStatus": .string(databaseIdentityStatus),
            "databaseCoreFileSizes": .dictionary(sizes),
        ]
        if let receipt = ProvenanceRecorder.loadEnvelope(from: database),
           receipt.workflowName == databaseInstallWorkflowName,
           receipt.options.resolvedDefaults["intendedFinalPath"]?.stringValue == database.path {
            if let catalogID = receipt.options.explicit["catalogID"]?.stringValue {
                identity["databaseCatalogID"] = .string(catalogID)
            }
            if let version = receipt.options.resolvedDefaults["requestedCatalogVersion"]?.stringValue
                ?? receipt.workflowVersion {
                identity["databaseCatalogVersion"] = .string(version)
            }
        }
        return identity
    }

    /// One warning line for each task failure TaxTriage ignored, naming the process, the sample, the exit status, the
    /// attempts when there were several and the key line of the task's stderr when the log carried one.
    static func warningLines(for failures: [TaxTriageIgnoredFailure]) -> [String] {
        failures.map { failure in
            let task = [failure.processPath, failure.taskLabel].first { !$0.isEmpty } ?? "a task Nextflow did not name"
            var line = "Warning: TaxTriage ignored the failure of \(task)"
            if let sampleID = failure.sampleID, !sampleID.isEmpty {
                line += " for sample \(sampleID)"
            }
            line += ", exit status \(failure.exitCode)"
            if let attempts = failure.attempts, attempts > 1 {
                line += " after \(attempts) attempts"
            }
            if let diagnostic = failure.diagnostic, !diagnostic.isEmpty {
                line += " (\(diagnostic))"
            }
            return line
        }
    }

    /// The warning lines of the task failures the result among `outputFiles` lists, none when no result is among them.
    static func ignoredFailureWarnings(inResultAmong outputFiles: [URL]) -> [String] {
        guard let resultFile = outputFiles.first(where: { $0.lastPathComponent == "taxtriage-result.json" }),
              let result = try? TaxTriageResult.load(from: resultFile.deletingLastPathComponent()) else {
            return []
        }
        return warningLines(for: result.ignoredFailures)
    }

    /// The TaxTriage step's resolved options, the version of the Nextflow that ran as `nextflowVersion`, read from the
    /// banner it printed into the log among `outputFiles`. Nil when no log there holds a banner.
    static func engineOptions(logAmong outputFiles: [URL]) -> [String: ParameterValue]? {
        guard let log = outputFiles.first(where: { $0.lastPathComponent == "nextflow.log" }),
              let text = try? String(contentsOf: log, encoding: .utf8),
              let version = nextflowVersion(inBanner: text) else {
            return nil
        }
        return ["nextflowVersion": .string(version)]
    }

    /// The version in Nextflow's banner line, `N E X T F L O W  ~  version 25.04.6`, or nil.
    static func nextflowVersion(inBanner text: String) -> String? {
        guard let banner = text.range(
            of: #"N E X T F L O W\s+~\s+version\s+[0-9][0-9A-Za-z.\-]*"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return text[banner].split(whereSeparator: \.isWhitespace).last.map(String.init)
    }
}
