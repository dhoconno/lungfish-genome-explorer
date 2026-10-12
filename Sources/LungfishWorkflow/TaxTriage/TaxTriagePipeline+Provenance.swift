// TaxTriagePipeline+Provenance.swift - The provenance record a TaxTriage run saves for itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Where a TaxTriage pipeline run hands its record (A2 M2, ARCH 3).
package enum TaxTriageRecording: Sendable {
    /// The app's route, the public `run(config:progress:)`. The pipeline saves its own record in the
    /// output folder.
    case pipelineSave
    /// A `.singleFolder` or `.sharedBatchRoot` unit of `taxtriage run`, whose folder is the result
    /// folder. The pipeline saves no record of its own and hands every step, input and option to the
    /// root record, which the executor writes there.
    case rootRecord(AnalysisRunUnitContext)
    /// A `.batchRoot` unit of `taxtriage run`. The sample keeps the pipeline's own record in its folder,
    /// and the unit hands the root record only run-level values.
    case unitRecord(AnalysisRunUnitContext)
}

extension TaxTriagePipeline {

    // MARK: - Provenance

    /// Finishes the run's record where `recording` sends it. The app's route and a batch sample save
    /// the pipeline's record in `outputDirectory`. A result folder on the executor saves none and hands
    /// the root record each step and input with the digests the recorder took, so nothing is hashed
    /// twice (S2), and the options under their homes, so no fact is written twice into one file.
    func finishTaxTriageRecord(
        recording: TaxTriageRecording,
        runID: UUID,
        outputDirectory: URL,
        description: String,
        exitCode: Int32,
        stderr: String,
        logFile: URL?
    ) async throws {
        guard case .rootRecord(let context) = recording else {
            try await saveTaxTriageProvenanceOrThrow(
                runID: runID,
                outputDirectory: outputDirectory,
                description: description,
                exitCode: exitCode,
                stderr: stderr,
                logFile: logFile
            )
            return
        }
        let parameters = await ProvenanceRecorder.shared.getRun(runID)?.parameters ?? [:]
        guard let envelope = await ProvenanceRecorder.shared.canonicalEnvelope(for: runID) else { return }
        for file in envelope.files where file.role == .input {
            context.recordInput(file)
        }
        envelope.steps.forEach(context.recordStep)
        context.recordOptions(TaxTriageRecordFacts.rootRecordOptions(fromRunParameters: parameters))
    }

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
    /// `pin` names the tag of the pinned revision, and the revision when the configuration chose none.
    nonisolated func provenanceParameters(
        for config: TaxTriageConfig,
        interleavedSplits: [InterleavedSampleSplit] = [],
        pin: NextflowPipelinePin? = nil
    ) -> [String: ParameterValue] {
        TaxTriageRecordFacts(config: config, interleavedSplits: interleavedSplits, pin: pin).runParameters
    }

    /// Records the TaxTriage step. A run that ended 0 names its result among `outputFiles`, and each task failure
    /// that TaxTriage ignored in it adds a warning line to the step's stderr (T8). The step's tool, version, tag and
    /// resolved options are the run's Nextflow facts (``TaxTriageRecordFacts/nextflowFacts(revision:pin:pipelineSource:)``),
    /// whose resolved options hold `pipelineSource` and the version of the Nextflow that ran, from the log among
    /// `outputFiles`.
    func recordTaxTriageProvenanceStep(
        runID: UUID,
        config: TaxTriageConfig,
        pin: NextflowPipelinePin,
        pipelineSource: NextflowPipelineSource,
        command: [String],
        outputFiles: [URL],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?
    ) async {
        let warnings = exitCode == 0 ? TaxTriageRecordFacts.ignoredFailureWarnings(inResultAmong: outputFiles) : []
        let stderrLines = ([stderr ?? ""] + warnings).filter { !$0.isEmpty }
        let nextflow = TaxTriageRecordFacts.nextflowFacts(
            revision: config.launchRevision(pin: pin),
            pin: pin,
            pipelineSource: pipelineSource
        )
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: nextflow.toolName,
            toolVersion: nextflow.toolVersion,
            githubReleaseVersion: nextflow.githubReleaseVersion,
            command: command,
            resolvedOptions: nextflow.resolvedOptions(logFile: TaxTriageRecordFacts.nextflowLog(among: outputFiles)),
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
/// - Every TaxTriage step is the tool `taxtriage` at the revision, with the release tag beside it (RT4). With the
///   pipeline source and the Nextflow version they are the step's ``NextflowRecordFacts`` (R1, T6), which the sample
///   steps of a serial batch record (`TaxTriageSerialBatchRunner.recordSampleProvenance`) do not take yet.
/// - The settings the run was asked for are explicit options. `classifiers` is a resolved default, because the launch
///   passes no `--classifiers` and TaxTriage runs its own default, Kraken 2 (Phase 2.9 decision R5).
/// - The plan of a record of one sample is the resolved default `readSetPlan`, the home decision E13 of Phase 2.7 names
///   (T7). A pooled record of several samples keeps its plans keyed by sample under `read_set_plans` in the explicit
///   options, the home released builds wrote, because one plan cannot hold several samples' plans.
/// - The Kraken 2 database is recorded as decision E9 of Phase 2.7 records EsViritu's, as resolved defaults, with the
///   source URL and source policy its install receipt names, and no placeholder of the receipt as a catalog entry or
///   version (``DatabaseReceiptPlaceholder``). Its status is the word `unpinned`, which ``DatabaseIdentityStatus`` reads.
/// - Each task failure TaxTriage ignored is one warning line (T8), and the run still ends `completed`.
///
/// The R1 and R2 halves of an interleaved file are scratch that the run removes, so no fact names one (T6). The record
/// names the durable interleaved file instead.
struct TaxTriageRecordFacts: Sendable, Equatable {
    /// The one tool name of a TaxTriage step, the name the batch record of a serial run already gives each sample.
    static let toolName = "taxtriage"
    /// The status of a TaxTriage database's identity. No digest pins it, and no database folder is hashed per run.
    static let databaseIdentityStatus = DatabaseIdentityStatus.unpinned.rawValue
    /// The workflow name of a database install receipt, the record an install writes into the database folder.
    static let databaseInstallWorkflowName = "metagenomics.database.install"
    /// The run parameters a record holds among its resolved defaults rather than its explicit options.
    static let resolvedDefaultKeys: Set<String> = [
        RecordedReadSetPlan.key, "classifiers", "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes",
        "databaseCatalogID", "databaseCatalogVersion", "databaseSourceURL", "databaseSourcePolicy",
    ]
    /// The settings the run was asked for.
    let explicitOptions: [String: ParameterValue]
    /// What the run resolved, the plan of a record of one sample and the identity of its database.
    let resolvedDefaults: [String: ParameterValue]

    init(
        config: TaxTriageConfig,
        interleavedSplits: [TaxTriagePipeline.InterleavedSampleSplit] = [],
        pin: NextflowPipelinePin? = nil
    ) {
        var explicit: [String: ParameterValue] = [
            "workflow": .string("taxtriage"),
            "sample_count": .integer(config.samples.count),
            "platform": .string(config.platform.rawValue),
            "top_hits_count": .integer(config.topHitsCount),
            "k2_confidence": .number(config.k2Confidence),
            "rank": .string(config.rank),
            "skip_assembly": .boolean(config.skipAssembly),
            "skip_krona": .boolean(config.skipKrona),
            "max_memory": .string(config.maxMemory),
            "max_cpus": .integer(config.maxCpus),
            "profile": .string(config.profile),
            "extraArgs": .string(AdvancedCommandLineOptions.join(config.extraArguments)),
            "output_directory": .file(config.outputDirectory),
            "remove_taxids": .string(config.effectiveRemoveTaxids ?? ""),
        ]
        // The revision that runs, the configuration's or else the pin's, with its tag (N4, R1).
        if let revision = config.revision ?? pin?.revision {
            explicit["revision"] = .string(revision)
            if let githubReleaseVersion = TaxTriageConfig.githubReleaseVersion(for: revision, pin: pin) {
                explicit["github_release_version"] = .string(githubReleaseVersion)
            }
        }
        if !interleavedSplits.isEmpty {
            explicit["interleaved_samples_split_to_r1_r2"] = .array(interleavedSplits.map { .string($0.sampleId) })
        }
        var resolved = Self.databaseIdentity(at: config.kraken2DatabasePath)
        // R5. The launch passes no `--classifiers`, so the classifiers TaxTriage ran are its default, not a choice.
        resolved["classifiers"] = .array(config.classifiers.map { .string($0) })
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

    /// The root record's options for a run that began with `parameters`, each under the home the
    /// pipeline's own save gives it, with the plan of a one-sample record in its one home (E13).
    static func rootRecordOptions(fromRunParameters parameters: [String: ParameterValue]) -> AnalysisRootRecordOptions {
        var resolved = parameters.filter { resolvedDefaultKeys.contains($0.key) }
        let plan = resolved.removeValue(forKey: RecordedReadSetPlan.key)
        return AnalysisRootRecordOptions(
            explicit: parameters.filter { !resolvedDefaultKeys.contains($0.key) },
            resolved: resolved,
            readSetPlan: plan
        )
    }

    /// The identity of the Kraken 2 database at `databaseURL`, as decision E9 gives EsViritu's. Its path, the size of
    /// each core file and a status that says no digest pins it. When the folder's install receipt names the folder and
    /// its install ended 0, also the source URL and source policy the receipt names, the catalog entry unless the
    /// receipt holds a placeholder for it, and as the version the first of the requested catalog version and the
    /// receipt's workflow version that is no placeholder. Nothing is hashed. Empty when the run names no database.
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
           receipt.exitStatus == 0,
           receipt.options.resolvedDefaults["intendedFinalPath"]?.stringValue == database.path {
            let installed = receipt.options.resolvedDefaults
            if let catalogID = DatabaseReceiptPlaceholder.named(receipt.options.explicit["catalogID"]?.stringValue) {
                identity["databaseCatalogID"] = .string(catalogID)
            }
            if let version = DatabaseReceiptPlaceholder.firstNamed(
                among: [installed["requestedCatalogVersion"]?.stringValue, receipt.workflowVersion]
            ) {
                identity["databaseCatalogVersion"] = .string(version)
            }
            if let sourceURL = installed["requestedSourceURL"]?.stringValue {
                identity["databaseSourceURL"] = .string(sourceURL)
            }
            if let sourcePolicy = installed["databaseSourcePolicy"]?.stringValue {
                identity["databaseSourcePolicy"] = .string(sourcePolicy)
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

    /// The Nextflow facts of the TaxTriage step of a run at `revision` from `pipelineSource`, the tool `taxtriage` at the
    /// revision, with the release tag beside it when the lock's pin or a `v` tag names one (RT4, R1, T6).
    static func nextflowFacts(
        revision: String,
        pin: NextflowPipelinePin?,
        pipelineSource: NextflowPipelineSource
    ) -> NextflowRecordFacts {
        NextflowRecordFacts(
            toolName: toolName,
            toolVersion: revision,
            githubReleaseVersion: TaxTriageConfig.githubReleaseVersion(for: revision, pin: pin),
            pipelineSource: pipelineSource
        )
    }

    /// The log LGE keeps of the engine, the first of `outputFiles` named `nextflow.log`, banner or not, or nil.
    static func nextflowLog(among outputFiles: [URL]) -> URL? {
        outputFiles.first { $0.lastPathComponent == "nextflow.log" }
    }
}
