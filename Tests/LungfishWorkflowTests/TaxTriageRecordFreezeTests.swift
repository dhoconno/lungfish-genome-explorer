// TaxTriageRecordFreezeTests.swift - What a TaxTriage run records today, frozen before lanes B2 and S1 change it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane TF-W. Every assertion states what the code does at the base of the phase. A later lane flips
// an assertion only where its decision in docs/plans/2026-10-11-phase-2-8.md says so. "BIO T5" in a doc comment is
// row T5 of the bioinformatics expert's inventory of the TaxTriage record for that phase, and the comment states the
// fact in full.
//
// No Nextflow, container or network is involved. Since 2.13 K1b the batch cases run the batch result of
// `TaxTriageAnalysisRunTool`, the one the executor publishes at the root of a TaxTriage batch, from unit reports that
// stand in for the engine. They ran `TaxTriageSerialBatchRunner`, whose root record no route wrote after 2.12 K1, and
// the facts only that root record held went with it. The record a single run writes for itself is built from
// `TaxTriagePipeline.provenanceParameters` and `recordReadSetSteps`, the two helpers the run calls. What the run does
// between them needs the engine, and `TaxTriageSampleRecordFreezeTests` pins it on the stand-in engine of lane TF-G.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageRecordFreezeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-record-freeze")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Helpers

    /// The twelve folders and files of a sample result that the tests below write, grouped by what the record does with them.
    private static let keptByTheRecord = [
        "count/{id}.fastq.gz", "fastp/{id}.fastp.fastq.gz", "fastp/{id}.fastp.json", "filterkraken/{id}.kraken2.report.txt",
        "top/{id}.top_report.tsv", "report/{id}.odr.txt", "report/multiqc_data/multiqc_confidences.txt",
        "minimap2/{id}.{id}.dwnld.references.bam",
    ]
    private static let prunedFromTheRecord = [
        "work/ab/cd1234/.command.sh", "download/{id}.dwnld.references.fasta", "workflow-source/taxtriage/main.nf",
    ]

    private static func paths(_ templates: [String], for id: String) -> [String] {
        templates.map { $0.replacingOccurrences(of: "{id}", with: id) }
    }

    /// Writes one small file per relative path under `directory` and returns their URLs in the order given.
    private static func write(_ relativePaths: [String], in directory: URL) throws -> [URL] {
        try relativePaths.map { relative in
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(relative)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// 2.13 K1b. The batch result of `batch` as `TaxTriageAnalysisRunTool` publishes it at the batch root, from one unit
    /// per sample in its own folder of the root. Each unit stands in for the engine. It writes `files` (sample-relative
    /// templates) into its folder and its result lists them all, as the real run lists what is on disk. It fails for
    /// the sample ids in `failing` with the reason its launch gave, and `ignored` are the task failures Nextflow ignored
    /// for a sample. Nil when no sample completed.
    private func publishedBatch(
        _ batch: TaxTriageConfig,
        files: [String] = TaxTriageRecordFreezeTests.keptByTheRecord,
        failing: Set<String> = [],
        ignored: [String: [TaxTriageIgnoredFailure]] = [:]
    ) throws -> TaxTriageResult? {
        let units = try batch.samples.enumerated().map { index, sample -> AnalysisUnitReport<TaxTriageUnitResult> in
            let id = sample.sampleId
            let folder = batchRoot.appendingPathComponent(id, isDirectory: true)
            // The executor makes the root and each unit's folder before the unit runs.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard !failing.contains(id) else {
                return AnalysisUnitReport(
                    index: index, label: id, sampleName: id, directory: folder, outcome: .failed(reason: "synthetic failure of \(id)")
                )
            }
            var sampleConfig = batch
            sampleConfig.samples = [sample]
            sampleConfig.outputDirectory = folder
            sampleConfig.sourceBundleURLs = batch.sourceBundleURLs.map { [$0[index]] }
            let urls = try Self.write(Self.paths(files, for: id), in: folder)
            let result = TaxTriageResult(
                config: sampleConfig,
                runtime: 1.5,
                exitCode: 0,
                outputDirectory: folder,
                reportFiles: urls.filter { $0.lastPathComponent.hasSuffix(".odr.txt") },
                allOutputFiles: urls,
                sourceBundleURLs: sampleConfig.sourceBundleURLs,
                ignoredFailures: ignored[id] ?? []
            )
            let value = TaxTriageUnitResult(result: result)
            return AnalysisUnitReport(
                index: index, label: id, sampleName: id, directory: folder,
                outcome: result.ignoredFailures.isEmpty ? .completed(value) : .completedWithWarning(value, reason: "ignored task failures")
            )
        }
        return try TaxTriageAnalysisRunTool.publishAggregateResult(of: units, planned: batch.samples, root: batchRoot)
    }

    private var batchRoot: URL { root.appendingPathComponent("batch", isDirectory: true) }

    private func sample(_ id: String) -> TaxTriageSample {
        TaxTriageSample(sampleId: id, fastq1: URL(fileURLWithPath: "/data/\(id).fastq.gz"))
    }

    /// A config with every setting the record can hold set to a value that is not its default, and the CPU count fixed.
    private func config(
        _ samples: [TaxTriageSample],
        output: URL? = nil,
        bundles: [URL]? = nil,
        everySetting: Bool = false
    ) -> TaxTriageConfig {
        let database = everySetting ? URL(fileURLWithPath: "/db/viral-kraken2") : nil
        var config = TaxTriageConfig(
            samples: samples,
            outputDirectory: output ?? batchRoot,
            kraken2DatabasePath: database,
            maxCpus: 4,
            sourceBundleURLs: bundles
        )
        if everySetting {
            config.topHitsCount = 7
            config.k2Confidence = 0.3
            config.rank = "G"
            config.skipKrona = true
            config.maxMemory = "8.GB"
            config.extraArguments = ["--foo", "bar"]
            config.removeTaxids = "9606 10090"
        }
        return config
    }

    private func record(in directory: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: directory), "no record in \(directory.path)")
    }

    private func relative(_ path: String, to directory: URL) -> String {
        // `standardizedFileURL` drops `/private` only from a path that exists, so a removed file keeps it.
        let standard = directory.standardizedFileURL.path
        let prefixes = Set([directory.path, standard, directory.resolvingSymlinksInPath().path, "/private" + standard])
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return path
    }

    private func makeFixtures() throws -> ReadSetFixtures {
        try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    private func planned(
        _ bundle: URL,
        as id: String,
        in fixtures: ReadSetFixtures,
        materializeInto directory: URL? = nil
    ) async throws -> TaxTriageSample {
        try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: id, fastq1: bundle),
            materializationDirectory: directory ?? root.appendingPathComponent("planned-\(UUID().uuidString)", isDirectory: true),
            materializer: fixtures.materializer
        )
    }

    // MARK: - BIO T2, T3 and T4, where a run goes and what the batch record holds

    // 2.13 K1b. Four cases ran the serial runner and pinned its root record, which no route wrote after 2.12 K1. They
    // went with it, and each fact the executor holds is pinned on the executor.
    // - BIO T2, one sample. The runner handed one sample straight to the pipeline and wrote nothing of its own. The
    //   executor runs one sample in the folder it names (`.sharedBatchRoot` or `.singleFolder`,
    //   `TaxTriageAnalysisRunToolPlanTests`), and its root record takes the pipeline's place
    //   (`TaxTriageAnalysisRunToolReplayTests.testAPlainOutputIsOneLaunchInTheResultFolderWhoseStepTheRootRecordHolds`).
    // - BIO T2, several samples. One launch per sample, in a folder of the root that the one sanitizer names, with the
    //   root record and the batch result at the root (`TaxTriageAnalysisRunToolPlanTests`,
    //   `TaxTriageAnalysisRunToolReplayTests.testABatchIsOneLaunchPerSampleFolderAndEachSampleKeepsItsOwnRecord`). The
    //   workflow name `TaxTriage Serial Batch` was the runner's alone. The executor's is `lungfish.taxtriage.run`.
    // - BIO T3. The runner rebuilt a `nextflow run` argv for each sample and closed its record with a step of its own,
    //   `lungfish-app-taxtriage-serial-batch` with the argv `lungfish-app taxtriage-serial-batch --output <root>`. Both
    //   were the runner's alone. A sample's own record holds the argv that ran
    //   (`TaxTriageSampleRecordFreezeTests.testAPlainSampleRecordsTheArgvThatRanAsItsOneStep`).
    // - BIO T4. The tool `taxtriage` at the revision, with the release tag beside it, which the same case pins on a
    //   sample's own record.

    // MARK: - BIO T5, a failed sample

    /// BIO T5. A sample whose run fails is a sample failure of the batch result, with the reason its launch gave, and
    /// the batch result exits 0 while any sample completed. Retargeted by 2.13 K1b onto the batch result of
    /// `TaxTriageAnalysisRunTool`. The failed sample's step in the serial runner's root record (exit 1, no outputs, the
    /// error as stderr) and that record's `completed` went with the runner. On the executor the failed sample keeps its
    /// own record and the root record its status, which case X4 of `TaxTriageCLIGUIParityReplayTests` pins.
    func testAFailedSampleIsASampleFailureOfTheBatchResultAndTheBatchStillCompletes() throws {
        let batch = config(["GoodA", "Bad", "GoodB"].map(sample))

        let result = try XCTUnwrap(try publishedBatch(batch, files: ["report/x.odr.txt"], failing: ["Bad"]))

        XCTAssertEqual(result.sampleFailures.map(\.sampleID), ["Bad"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try TaxTriageResult.load(from: batchRoot).sampleFailures.map(\.errorDescription), ["synthetic failure of Bad"])
    }

    /// BIO T5. When every sample fails, no batch result is written. Retargeted by 2.13 K1b. The serial runner threw
    /// `TaxTriageSerialBatchError.allSamplesFailed` and saved its root record `failed` with a step at exit 1 for each
    /// sample. The executor keeps each sample's own record, and the error's words stay those the app shows for such a
    /// batch (`CLIClassifierRunner`).
    func testWhenEverySampleFailsNoBatchResultIsWritten() throws {
        let batch = config(["A", "B"].map(sample))

        XCTAssertNil(try publishedBatch(batch, failing: ["A", "B"]), "no batch result when no sample completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent("taxtriage-result.json").path))
    }

    // MARK: - BIO T6 and T7, the run parameters and the plan

    private static let settingKeys: Set<String> = [
        "workflow", "sample_count", "platform", "classifiers", "top_hits_count", "k2_confidence", "rank",
        "skip_assembly", "skip_krona", "max_memory", "max_cpus", "profile", "revision", "extraArgs",
        "output_directory", "remove_taxids",
    ]

    /// BIO T6. A run's parameters hold the sixteen settings and the release version, the ids of the samples split to
    /// R1 and R2 when there are any, and `read_set_plans` when a plan has something to say. Lane B2 (RT5) adds the
    /// Kraken 2 database as decision E9 records EsViritu's, its path, the size of each core file it holds (none here,
    /// the folder does not exist) and the status `unpinned`, which the record keeps among its resolved defaults. Lane
    /// B11 M2 (R5) keeps `classifiers` there too, because the launch passes no `--classifiers`. No parameter names a
    /// container image.
    func testTheRunParametersHoldSixteenSettingsAndTheReleaseTag() throws {
        XCTAssertEqual(Self.settingKeys.count, 16)
        let c = config([sample("A")], everySetting: true)
        let pipeline = TaxTriagePipeline()

        let parameters = pipeline.provenanceParameters(for: c, pin: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())

        let databaseKeys: Set<String> = ["databasePath", "databaseIdentityStatus", "databaseCoreFileSizes"]
        XCTAssertEqual(Set(parameters.keys), Self.settingKeys.union(["github_release_version"]).union(databaseKeys))
        XCTAssertEqual(parameters["workflow"], .string("taxtriage"))
        XCTAssertEqual(parameters["sample_count"], .integer(1))
        XCTAssertEqual(parameters["platform"], .string("ILLUMINA"))
        XCTAssertEqual(parameters["classifiers"], .array([.string("kraken2")]))
        XCTAssertEqual(parameters["top_hits_count"], .integer(7))
        XCTAssertEqual(parameters["k2_confidence"], .number(0.3))
        XCTAssertEqual(parameters["rank"], .string("G"))
        XCTAssertEqual(parameters["skip_assembly"], .boolean(true))
        XCTAssertEqual(parameters["skip_krona"], .boolean(true))
        XCTAssertEqual(parameters["max_memory"], .string("8.GB"))
        XCTAssertEqual(parameters["max_cpus"], .integer(4))
        XCTAssertEqual(parameters["profile"], .string("docker"))
        XCTAssertEqual(parameters["revision"], .string(c.launchRevision(pin: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())))
        XCTAssertEqual(parameters["extraArgs"], .string("--foo bar"))
        XCTAssertEqual(parameters["output_directory"], .file(c.outputDirectory))
        XCTAssertEqual(parameters["remove_taxids"], .string("9606 10090"))
        XCTAssertEqual(parameters["github_release_version"], .string(try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin().releaseVersion))
        XCTAssertEqual(parameters["databasePath"], .string("/db/viral-kraken2"), "flipped by B2 (RT5), the database is named")
        XCTAssertEqual(parameters["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertEqual(parameters["databaseCoreFileSizes"], .dictionary([:]))
        let resolved = TaxTriageRecordFacts.recordOptions(fromRunParameters: parameters).resolvedDefaults
        XCTAssertEqual(
            resolved.keys.sorted(),
            databaseKeys.union(["classifiers", "sample_count"]).sorted(),
            "the save keeps the database among the resolved defaults, moved by B11 M2 (R5) the classifiers too, and moved by A2 M3 (B12 ruling H1) sample_count"
        )
        XCTAssertEqual(resolved["sample_count"], .integer(1), "B12 ruling H1")

        let split = TaxTriagePipeline.InterleavedSampleSplit(
            sampleId: "A",
            source: URL(fileURLWithPath: "/data/A.fastq"),
            r1: URL(fileURLWithPath: "/scratch/A/R1.fastq"),
            r2: URL(fileURLWithPath: "/scratch/A/R2.fastq"),
            pairCount: 2,
            wallTime: 0
        )
        let withSplit = pipeline.provenanceParameters(for: c, interleavedSplits: [split], pin: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())
        XCTAssertEqual(
            Set(withSplit.keys),
            Self.settingKeys.union(["github_release_version", "interleaved_samples_split_to_r1_r2"]).union(databaseKeys)
        )
        XCTAssertEqual(withSplit["interleaved_samples_split_to_r1_r2"], .array([.string("A")]))
        XCTAssertEqual(
            TaxTriageRecordFacts.recordOptions(fromRunParameters: withSplit).resolvedDefaults["interleaved_samples_split_to_r1_r2"],
            .array([.string("A")]),
            "moved by A2 M3 (B12 ruling H2), the save files the split ids among the resolved defaults"
        )
    }

    // BIO T6, the batch record. `testTheBatchRecordHoldsTheSameSettingsAndNoPlan` pinned the options of the serial
    // runner's root record, under the workflow `taxtriage-serial-batch`, and went with that record in 2.13 K1b. The root
    // record of a batch on the executor keeps the run-level values only (B12 row 256), which
    // `TaxTriageAnalysisRunToolReplayTests` and case X3 of `TaxTriageCLIGUIParityReplayTests` pin.

    /// Saves a run holding `parameters` with the pipeline's own save, as a TaxTriage run saves its record, and reads
    /// the record back.
    private func savedRecord(parameters: [String: ParameterValue], as name: String) async throws -> ProvenanceEnvelope {
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage", parameters: parameters)
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await TaxTriagePipeline().saveTaxTriageProvenanceOrThrow(
            runID: runID,
            outputDirectory: directory,
            description: "completed run",
            exitCode: -1,
            stderr: "",
            logFile: nil
        )
        return try record(in: directory)
    }

    /// BIO T7. A pooled run of several samples records its plans as `read_set_plans`, keyed by sample id, among the run
    /// parameters, which the recorder merges into `options.explicit`. At the base the one reader of a plan looked for
    /// `readSetPlan` only, so it did not read the keyed form. Each sample of a several-sample app run writes a record of
    /// one sample. Plan decision T7, applied by lane B2, records the plan of a record of one sample as the resolved
    /// default `readSetPlan`, where the reader finds it, and keeps no keyed plan there, because a writer keeps one home
    /// for a plan. The three assertions on that record were flipped by B2. A pooled record keeps the keyed form, and
    /// since B2's M3 the reader gives each of its plans by sample id while the record has no one plan, so the assertion
    /// on its reader was flipped by B2, and the test's name with it.
    func testPlansAreKeyedBySampleOnlyInAPooledRecordAndTheReaderFindsEveryPlan() async throws {
        let fixtures = try makeFixtures()
        let mixed = try await planned(fixtures.mixedRoot, as: "mixed", in: fixtures)
        let merged = try await planned(fixtures.mergeDerivative, as: "merged", in: fixtures)
        let plain = try await planned(fixtures.singleRoot, as: "plain", in: fixtures)
        let parameters = TaxTriagePipeline().provenanceParameters(for: config([mixed, merged, plain]))
        guard case .dictionary(let plans)? = parameters["read_set_plans"] else {
            return XCTFail("a plan with something to say is recorded: \(parameters.keys.sorted())")
        }
        XCTAssertEqual(Set(plans.keys), ["mixed", "merged"], "keyed by sample id, and a sample with nothing to say adds nothing")
        for plan in plans.values {
            guard case .dictionary(let fields) = plan else { return XCTFail("\(plan)") }
            XCTAssertEqual(fields["capability"], .string("pairs_only_when_all_paired"))
            XCTAssertNotEqual(fields["singleReadReason"], .null, "the plan states why mates ran as single reads")
        }

        let pooled = try await savedRecord(parameters: parameters, as: "pooled-record")
        XCTAssertEqual(pooled.options.resolvedDefaults["sample_count"], .integer(3), "moved by A2 M3 (B12 ruling H1)")
        XCTAssertNil(pooled.options.explicit["sample_count"], "B12 ruling H1")
        XCTAssertEqual(Set(try XCTUnwrap(pooled.options.explicit["read_set_plans"]?.dictionaryValue).keys), ["mixed", "merged"])
        XCTAssertNil(pooled.readSetPlan, "a pooled record of several samples has no one plan")
        XCTAssertEqual(
            pooled.readSetPlansBySample.mapValues(\.fields),
            plans.compactMapValues(\.dictionaryValue),
            "flipped by B2 (T7, M3), the reader gives each sample's plan by its id"
        )
        XCTAssertEqual(pooled.readSetPlansBySample["mixed"]?.place, .explicitOptionsKeyedBySample(sampleID: "mixed"))

        let oneSample = TaxTriagePipeline().provenanceParameters(for: config([mixed]))
        let single = try await savedRecord(parameters: oneSample, as: "single-record")
        XCTAssertNil(single.options.explicit["read_set_plans"], "flipped by B2 (T7), a record of one sample keeps no keyed plan")
        XCTAssertEqual(single.readSetPlansBySample, [:])
        XCTAssertEqual(
            single.options.resolvedDefaults,
            ["readSetPlan": plans["mixed"]!, "classifiers": .array([.string("kraken2")]), "sample_count": .integer(1)],
            "flipped by B2 (T7), the plan is a resolved default, moved by B11 M2 (R5) the classifiers are one, and moved by A2 M3 (B12 ruling H1) sample_count"
        )
        XCTAssertNil(single.options.explicit["readSetPlan"])
        XCTAssertNil(single.options.explicit["sample_count"], "B12 ruling H1")
        XCTAssertEqual(single.readSetPlan?.place, .resolvedDefaults, "flipped by B2 (T7), the reader finds the plan")
        XCTAssertEqual(single.readSetPlan?.fields["capability"], .string("pairs_only_when_all_paired"))
    }

    // MARK: - BIO T8, T9 and T10, the files a record names that the run removes

    /// BIO T8. The split of an interleaved file into R1 and R2 is a step that names its source as the input, no
    /// outputs, and in its argv the folder of the halves, which is inside the run's scratch folder
    /// `.lungfish-interleaved-split`. The run removes that folder when it ends. The step and the run's files name the
    /// durable interleaved file, never a half as a file. (The TaxTriage step's own input list is not reachable without
    /// the engine.) Plan decision T6 keeps the halves scratch and has the record cite only the durable file, so the
    /// assertion on the folder in the argv may flip with lane B2. The split is also the first step the run records,
    /// so the record names it as the run's own tool, version and argv until lane B2 gives it one tool name (RT4).
    func testTheInterleavedSplitStepNamesItsSourceAndNoOutputs() async throws {
        let fixtures = try makeFixtures()
        let interleaved = try await planned(fixtures.interleavedRoot, as: "inter", in: fixtures)
        let c = config([interleaved])
        let splitRoot = root.appendingPathComponent(TaxTriagePipeline.interleavedSplitDirectoryName, isDirectory: true)

        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(in: c, splitRoot: splitRoot)

        let split = try XCTUnwrap(prepared.splits.first)
        XCTAssertEqual(TaxTriagePipeline.interleavedSplitDirectoryName, ".lungfish-interleaved-split")
        for half in [split.r1, split.r2] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: half.path), "the halves exist while the run reads them")
            XCTAssertEqual(relative(half.path, to: splitRoot).split(separator: "/").first, "inter")
        }
        XCTAssertEqual(prepared.config.samples[0].fastq1, split.r1, "the engine reads the halves")
        XCTAssertEqual(prepared.config.samples[0].fastq2, split.r2)
        XCTAssertEqual(split.source.standardizedFileURL, interleaved.fastq1.standardizedFileURL)

        let parameters = TaxTriagePipeline().provenanceParameters(for: c, interleavedSplits: prepared.splits)
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage", parameters: parameters)
        await TaxTriagePipeline.recordReadSetSteps(runID: runID, config: c, splits: prepared.splits)
        let recorded = await ProvenanceRecorder.shared.canonicalEnvelope(for: runID)
        let envelope = try XCTUnwrap(recorded)

        // The recorder's canonical envelope holds the parameters the run began with as explicit options. The save
        // files the split ids among the resolved defaults (B12 ruling H2), which TaxTriageSampleRecordFreezeTests
        // pins on the saved record.
        XCTAssertEqual(envelope.options.explicit["interleaved_samples_split_to_r1_r2"], .array([.string("inter")]))
        XCTAssertNil(envelope.options.resolvedDefaults["interleaved_samples_split_to_r1_r2"])
        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(envelope.steps.count, 1)
        XCTAssertEqual(step.toolName, "Lungfish TaxTriage Interleaved Split")
        XCTAssertEqual(
            envelope.toolName, "Lungfish TaxTriage Interleaved Split",
            "may flip with B2 (RT4), the first recorded step names the run's tool"
        )
        XCTAssertEqual(envelope.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.argv, step.argv)
        XCTAssertEqual(step.inputs.map { URL(fileURLWithPath: $0.path).standardizedFileURL }, [split.source.standardizedFileURL])
        XCTAssertEqual(step.outputs.count, 0, "the halves are not the step's outputs")
        XCTAssertEqual(step.argv.count, 4)
        XCTAssertEqual(Array(step.argv.prefix(3)), ["LungfishWorkflow", "deinterleave-fastq", split.source.path])
        XCTAssertEqual(
            URL(fileURLWithPath: step.argv[3]).standardizedFileURL,
            splitRoot.appendingPathComponent("inter", isDirectory: true).standardizedFileURL,
            "the argv names the folder of the halves, which the run removes"
        )
        XCTAssertEqual(step.resolvedOptions["sample"], .string("inter"))
        XCTAssertEqual(step.resolvedOptions["readLayout"], .string(FASTQInputLayout.strictlyInterleaved.rawValue))
        XCTAssertEqual(step.resolvedOptions["pairs"], .integer(2))
        let named = envelope.files.map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        XCTAssertFalse(named.contains(split.r1.standardizedFileURL) || named.contains(split.r2.standardizedFileURL))
    }

    /// BIO T9. A virtual bundle is materialized before TaxTriage reads it, and the read set plan of TaxTriage has no
    /// step of its own (the capability `pairs_only_when_all_paired` never writes one), so nothing records the
    /// materialization. The bundle appears only in the result file `taxtriage-result.json`, which the sidebar reads.
    /// Retargeted by 2.13 K1b onto the batch result of `TaxTriageAnalysisRunTool`. The serial runner's root record, with
    /// a `taxtriage` step per sample and its own batch step, went with the runner. A sample's own record names the
    /// materialized file and no step for it
    /// (`TaxTriageSampleRecordFreezeTests.testAMaterializedSampleRecordsTheMaterializedFileAndNoStepForIt`).
    func testAMaterializedVirtualBundleRecordsNoStepAndNoLineageToItsBundle() async throws {
        let fixtures = try makeFixtures()
        let materialized = root.appendingPathComponent("materialized-inputs", isDirectory: true)
        let a = try await planned(fixtures.subsetOfSingle, as: "A", in: fixtures, materializeInto: materialized)
        let b = try await planned(fixtures.subsetOfInterleaved, as: "B", in: fixtures, materializeInto: materialized)
        XCTAssertEqual(a.readSetPlan?.wasMaterialized, true)
        XCTAssertEqual(a.readSetPlan?.steps.count, 0, "the plan has no step to record")
        let bundles = [fixtures.subsetOfSingle, fixtures.subsetOfInterleaved]

        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage")
        await TaxTriagePipeline.recordReadSetSteps(runID: runID, config: config([a]), splits: [])
        let recorded = await ProvenanceRecorder.shared.canonicalEnvelope(for: runID)
        let single = try XCTUnwrap(recorded)
        XCTAssertEqual(single.steps.count, 0, "a sample's own record has no step for the materialization either")

        let result = try XCTUnwrap(try publishedBatch(config([a, b], bundles: bundles), files: []))

        XCTAssertEqual(result.sourceBundleURLs, bundles)
        XCTAssertEqual(try TaxTriageResult.load(from: batchRoot).sourceBundleURLs, bundles, "only the result file names them")
    }

    // BIO T10. `testTheRecordNamesMaterializedInputsThatTheCallerKeeps` ran the serial runner and read the inputs its
    // root record named, and went with that record in 2.13 K1b. A sample's own record names its materialized input with
    // its digest (`TaxTriageSampleRecordFreezeTests.testAMaterializedSampleRecordsTheMaterializedFileAndNoStepForIt`),
    // and `TaxTriageKeptInputsReplayTests` keeps those inputs where the record says (O1).

    // MARK: - BIO T11, the files a record names

    /// BIO T11. A batch result names every file of its samples' folders except those under `work`, `download` and
    /// `workflow-source`, and `taxtriage-result.json`, so it names `count/`, the fastp FASTQ and the other folders that
    /// `build-db taxtriage` removes afterwards (see `BuildDbTaxTriageCleanupFreezeTests`). Retargeted by 2.13 K1b onto
    /// the batch result of `TaxTriageAnalysisRunTool`. The serial runner's root record named the same files on each
    /// sample's step and sorted its result by path. The executor keeps the samples' request order
    /// (`TaxTriageAggregateResultDurabilityTests`), and a sample's own record names its files
    /// (`TaxTriageSampleRecordFreezeTests.testAPlainSampleRecordsTheArgvThatRanAsItsOneStep`).
    func testTheBatchResultNamesEveryOutputFileExceptWorkDownloadAndWorkflowSource() throws {
        XCTAssertEqual(TaxTriageOutputArtifactPolicy.prunableDirectoryNames, ["work", "download", "workflow-source"])
        let files = Self.keptByTheRecord + Self.prunedFromTheRecord
        let batch = config(["A", "B"].map(sample))

        let result = try XCTUnwrap(try publishedBatch(batch, files: files))

        let expected = (["A", "B"].flatMap { id in Self.paths(Self.keptByTheRecord, for: id).map { "\(id)/\($0)" } } + ["taxtriage-result.json"]).sorted()
        XCTAssertEqual(result.allOutputFiles.map { relative($0.path, to: batchRoot) }.sorted(), expected)
        // The rule is by path component below the output folder, wherever the component sits.
        let policy = TaxTriageOutputArtifactPolicy.self
        XCTAssertFalse(policy.isRetainedOutputFile(batchRoot.appendingPathComponent("A/report/work/x.tsv"), outputDirectory: batchRoot))
        XCTAssertTrue(policy.isRetainedOutputFile(batchRoot.appendingPathComponent("A/count/x.fastq.gz"), outputDirectory: batchRoot))
    }

    // MARK: - BIO T14, an ignored task failure

    /// BIO T14. Nextflow exits 0 when TaxTriage ignores an errored task, and the failure is in `taxtriage-result.json`.
    /// Retargeted by 2.13 K1b onto the batch result of `TaxTriageAnalysisRunTool`, which keeps the failure. The warning
    /// line on the failed sample's step of the serial runner's root record went with the runner. A sample's own record
    /// holds that line and stays completed
    /// (`TaxTriageSampleRecordFreezeTests.testAnIgnoredTaskFailureLeavesExitZeroAWarningLineAndACompletedRecord`).
    func testAnIgnoredTaskFailureIsKeptInTheBatchResult() throws {
        let failure = TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN",
            processName: "MINIMAP2_ALIGN",
            taskLabel: "A.MINIMAP2_ALIGN (A)",
            sampleID: "A",
            exitCode: 137,
            attempts: 3,
            diagnostic: "Killed: minimap2 -ax sr -t 14"
        )

        let result = try XCTUnwrap(try publishedBatch(config(["A", "B"].map(sample)), files: ["report/x.odr.txt"], ignored: ["A": [failure]]))

        XCTAssertEqual(result.ignoredFailures, [failure])
        XCTAssertEqual(try TaxTriageResult.load(from: batchRoot).ignoredFailures, [failure])
    }
}
