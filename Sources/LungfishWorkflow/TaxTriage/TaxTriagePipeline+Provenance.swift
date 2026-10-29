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

    /// The sample the TaxTriage step of an executor launch names, the launch's one sample, because
    /// a record of one sample otherwise names it only through a split or `cat` step (B12, 2.8 row
    /// 256). The app's route and a pooled launch of several samples name none.
    func stepSample(of config: TaxTriageConfig) -> String? {
        if case .pipelineSave = self { return nil }
        return config.samples.count == 1 ? config.samples[0].sampleId : nil
    }

    /// How a launch that ends now leaves its engine scratch (N7, `NextflowEngineProcess.finish`). A
    /// cancelled executor launch leaves it for the abandoned-scratch sweep, because its cancelled record
    /// is the root record, which the executor writes after the unit returns (N5). The app's route and
    /// every launch that was not cancelled remove it.
    func scratchDisposition(cancelled: Bool) -> NextflowScratchDisposition {
        if case .pipelineSave = self { return .remove }
        return cancelled ? .leaveForSweep : .remove
    }
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
        guard let envelope = await ProvenanceRecorder.shared.canonicalEnvelope(for: runID) else {
            // The root record would lack the TaxTriage step and its inputs, so the run fails instead.
            throw TaxTriagePipelineError.pipelineFailed(
                exitCode: -1,
                stderr: "The TaxTriage record of run \(runID.uuidString) is missing, so the run cannot hand its steps to the root record.",
                logFile: logFile
            )
        }
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

    /// Records the TaxTriage step. Each task failure TaxTriage ignored in a run that ended 0 adds a warning line to the
    /// step's stderr (T8), from `ignoredFailures`, the result's list in memory, so a result file that fails to decode
    /// loses none (B12, 2.8 row 256). The step's tool, version, tag and resolved options are the run's Nextflow facts
    /// (``TaxTriageRecordFacts/nextflowFacts(revision:pin:pipelineSource:)``), whose resolved options hold
    /// `pipelineSource` and the version of the Nextflow that ran, from the log among `outputFiles`, and `sample`, the
    /// one sample of an executor launch (``TaxTriageRecording/stepSample(of:)``).
    func recordTaxTriageProvenanceStep(
        runID: UUID,
        config: TaxTriageConfig,
        pin: NextflowPipelinePin,
        pipelineSource: NextflowPipelineSource,
        command: [String],
        outputFiles: [URL],
        exitCode: Int32,
        wallTime: TimeInterval,
        stderr: String?,
        ignoredFailures: [TaxTriageIgnoredFailure] = [],
        sample: String? = nil
    ) async {
        let warnings = exitCode == 0 ? TaxTriageRecordFacts.warningLines(for: ignoredFailures) : []
        let stderrLines = ([stderr ?? ""] + warnings).filter { !$0.isEmpty }
        let nextflow = TaxTriageRecordFacts.nextflowFacts(
            revision: config.launchRevision(pin: pin),
            pin: pin,
            pipelineSource: pipelineSource
        )
        var resolvedOptions = nextflow.resolvedOptions(logFile: TaxTriageRecordFacts.nextflowLog(among: outputFiles))
        if let sample {
            resolvedOptions["sample"] = .string(sample)
        }
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: nextflow.toolName,
            toolVersion: nextflow.toolVersion,
            githubReleaseVersion: nextflow.githubReleaseVersion,
            command: command,
            resolvedOptions: resolvedOptions,
            inputs: inputRecords(for: config),
            outputs: outputRecords(for: outputFiles),
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr == nil && stderrLines.isEmpty ? nil : stderrLines.joined(separator: "\n")
        )
    }

    func inputRecords(for config: TaxTriageConfig) -> [FileRecord] {
        let reads = config.samples.flatMap { sample in
            ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? []))
                .map { url in
                    ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
                }
        }
        return reads + TaxTriageRecordFacts.databaseReferenceRecords(at: config.kraken2DatabasePath)
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
///   pipeline source and the Nextflow version they are the step's ``NextflowRecordFacts`` (R1, T6).
/// - The settings the run was asked for are explicit options. `classifiers` is a resolved default, because the launch
///   passes no `--classifiers` and TaxTriage runs its own default, Kraken 2 (Phase 2.9 decision R5). `sample_count`
///   and `interleaved_samples_split_to_r1_r2` are resolved defaults too, because LGE counts the samplesheet rows it
///   built and decides on a split itself (Phase 2.9 B12 rulings H1 and H2). Released records hold both as explicit
///   options.
/// - The plan of a record of one sample is the resolved default `readSetPlan`, the home decision E13 of Phase 2.7 names
///   (T7). A pooled record of several samples keeps its plans keyed by sample under `read_set_plans` in the explicit
///   options, the home released builds wrote, because one plan cannot hold several samples' plans.
/// - The Kraken 2 database is recorded as decision E9 of Phase 2.7 records EsViritu's, as resolved defaults, with the
///   source URL and source policy its install receipt names, and no placeholder of the receipt as a catalog entry or
///   version (``DatabaseReceiptPlaceholder``). Its status is `pinned` with the receipt's payload digest when the receipt
///   adds up to its own digest, and `unpinned` otherwise (DB-IDENTITY, 3.1), words ``DatabaseIdentityStatus`` reads. The
///   references the run fetches from NCBI are `fetchedReferences`, a live snapshot with the run's start and the kept
///   gcfmap listings.
/// - Each task failure TaxTriage ignored is one warning line (T8), and the run still ends `completed`.
/// - The negative controls a user named are the explicit option `negative_controls`, present only when one was named
///   (2.10 T4). A mark a bundle's sample role makes is no option of the record.
///
/// The R1 and R2 halves of an interleaved file are scratch that the run removes, so no fact names one (T6). The record
/// names the durable interleaved file instead.
struct TaxTriageRecordFacts: Sendable, Equatable {
    /// The one tool name of a TaxTriage step, the name the batch record of a serial run already gives each sample.
    static let toolName = "taxtriage"
    /// The status of a TaxTriage database's identity when no install receipt pins it, the word its record has always
    /// had. A receipt that adds up to its own digest gives `pinned` and the digest instead. No database folder is hashed
    /// per run.
    static let databaseIdentityStatus = DatabaseIdentityStatus.unpinned.rawValue
    /// The workflow name of a database install receipt, the record an install writes into the database folder.
    static let databaseInstallWorkflowName = "metagenomics.database.install"
    /// The run parameters a record holds among its resolved defaults rather than its explicit options.
    static let resolvedDefaultKeys: Set<String> = [
        RecordedReadSetPlan.key, "classifiers", "sample_count", "interleaved_samples_split_to_r1_r2",
        "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes",
        "databaseCatalogID", "databaseCatalogVersion", "databaseSourceURL", "databaseSourcePolicy",
        "databaseDigest", "databaseIdentityNote", "fetchedReferences",
    ]
    /// The settings the run was asked for.
    let explicitOptions: [String: ParameterValue]
    /// What the run resolved, the plan of a record of one sample and the identity of its database.
    let resolvedDefaults: [String: ParameterValue]

    init(
        config: TaxTriageConfig,
        interleavedSplits: [TaxTriagePipeline.InterleavedSampleSplit] = [],
        pin: NextflowPipelinePin? = nil,
        runStart: Date = Date()
    ) {
        var explicit: [String: ParameterValue] = [
            "workflow": .string("taxtriage"),
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
        // 2.10 T4. The negative controls the user named, recorded only when given.
        let namedControls = Self.namedNegativeControls(in: config)
        if !namedControls.isEmpty {
            explicit["negative_controls"] = .array(namedControls.map { .string($0) })
        }
        var resolved = Self.databaseIdentity(at: config.kraken2DatabasePath)
        // DB-IDENTITY. The references TaxTriage fetches from NCBI during the run are a live snapshot that began with it.
        resolved.merge(Self.fetchedReferences(of: config, fetchedAt: runStart).resolvedDefaults) { current, _ in current }
        // R5. The launch passes no `--classifiers`, so the classifiers TaxTriage ran are its default, not a choice.
        resolved["classifiers"] = .array(config.classifiers.map { .string($0) })
        // B12 rulings H1 and H2. LGE counts the samplesheet rows it built and decides on a split itself.
        resolved["sample_count"] = .integer(config.samples.count)
        if !interleavedSplits.isEmpty {
            resolved["interleaved_samples_split_to_r1_r2"] = .array(interleavedSplits.map { .string($0.sampleId) })
        }
        if config.samples.count == 1 {
            if let plan = config.samples[0].readSetPlan?.provenanceParameters[RecordedReadSetPlan.key] {
                resolved[RecordedReadSetPlan.key] = plan
            }
        } else {
            explicit.merge(TaxTriagePipeline.readSetProvenanceParameters(for: config)) { current, _ in current }
        }
        // SW13. A platform the user did not choose, one a bundle recorded or the default, is what the run resolved, and
        // the record names where it came from. A platform the user chose stays an explicit option with no source.
        if config.platformSource != .chosen {
            explicit["platform"] = nil
            resolved["platform"] = .string(config.platform.rawValue)
            resolved[Self.platformSourceKey] = .string(config.platformSource.rawValue)
        }
        explicitOptions = explicit
        resolvedDefaults = resolved
    }

    /// The samples a user marked as negative controls, by `--negative-control` or by the wizard's own mark, in sample
    /// order (2.10 T4). Each is a marked sample whose bundle's sample role marks no negative control. A mark the role
    /// makes comes from the input, so the record names no option for it, and a sample both mark counts as the role's.
    static func namedNegativeControls(in config: TaxTriageConfig) -> [String] {
        config.samples
            .filter { sample in
                let roleMarks = sample.metadata.map { TaxTriageAnalysisRunTool.negativeControlRoles.contains($0.sampleRole) } ?? false
                return sample.isNegativeControl && !roleMarks
            }
            .map(\.sampleId)
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
        let keys = resolvedKeys(in: parameters)
        return ProvenanceOptions(resolvedDefaults: parameters.filter { keys.contains($0.key) })
    }

    /// The root record's options for a run that began with `parameters`, each under the home the
    /// pipeline's own save gives it, with the plan of a one-sample record in its one home (E13).
    static func rootRecordOptions(fromRunParameters parameters: [String: ParameterValue]) -> AnalysisRootRecordOptions {
        let keys = resolvedKeys(in: parameters)
        var resolved = parameters.filter { keys.contains($0.key) }
        let plan = resolved.removeValue(forKey: RecordedReadSetPlan.key)
        return AnalysisRootRecordOptions(
            explicit: parameters.filter { !keys.contains($0.key) },
            resolved: resolved,
            readSetPlan: plan
        )
    }

    /// The key beside a resolved `platform` that names where the platform came from (SW13).
    static let platformSourceKey = "platformSource"

    /// The keys of `parameters` a record files as resolved defaults. The platform joins them, with its source key, when
    /// the parameters name a source, which only a platform the user did not choose does (SW13). A platform the user
    /// chose carries no source key and stays among the explicit options.
    static func resolvedKeys(in parameters: [String: ParameterValue]) -> Set<String> {
        parameters[platformSourceKey] == nil ? resolvedDefaultKeys : resolvedDefaultKeys.union(["platform", platformSourceKey])
    }

    /// The identity of the Kraken 2 database at `databaseURL`, as decision E9 gives EsViritu's. Its path, the size of
    /// each core file and a status that says no digest pins it. When the folder's install receipt names the folder and
    /// its install ended 0, also the source URL and source policy the receipt names, the catalog entry unless the
    /// receipt holds a placeholder for it, and as the version the first of the requested catalog version and the
    /// receipt's workflow version that is no placeholder. When the receipt adds up to its own digest the status is `pinned`
    /// and `databaseDigest` is that digest, and a receipt that does not add up gives `databaseIdentityNote`
    /// (DB-IDENTITY, 3.1). Nothing is hashed. Empty when the run names no database.
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
            "databaseCoreFileSizes": .dictionary(sizes),
        ]
        identity.merge(MetagenomicsDatabaseReceiptReference.identityFacts(
            of: MetagenomicsDatabaseReceiptReference.resolve(databasePath: database)
        )) { current, _ in current }
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

    /// The references TaxTriage fetched from NCBI during the run, a live snapshot (decision R4 of Phase 2.9, DB-IDENTITY of
    /// 3.1). The entry names the run's start as the date of the fetch and the kept
    /// `combine/<sample>.combined.gcfmap.tsv` of each sample as the files that list what it fetched.
    static func fetchedReferences(of config: TaxTriageConfig, fetchedAt: Date) -> NextflowDatabaseEntry {
        NextflowDatabaseEntry(
            role: "fetchedReferences",
            status: .liveSnapshot,
            fetchedAt: fetchedAt,
            listingFiles: config.samples.map {
                config.outputDirectory.appendingPathComponent("combine/\($0.sampleId).combined.gcfmap.tsv")
            }
        )
    }

    /// The Kraken 2 database as a reference input of a step, when its install receipt adds up to its own digest. The
    /// record holds the aggregate SHA-256 the receipt states and the payload size, and nothing is hashed. A database
    /// with no receipt that adds up adds nothing.
    static func databaseReferenceRecords(at databaseURL: URL?) -> [FileRecord] {
        guard let databaseURL,
              let reference = MetagenomicsDatabaseReceiptReference.resolve(databasePath: databaseURL)?.reference else {
            return []
        }
        return [
            FileRecord(
                path: reference.path,
                sha256: reference.checksumSHA256,
                sizeBytes: reference.fileSize,
                format: .unknown,
                role: .reference
            ),
        ]
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
