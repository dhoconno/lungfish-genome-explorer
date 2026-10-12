// TaxTriageRecordFreezeTests.swift - What a TaxTriage run records today, frozen before lanes B2 and S1 change it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane TF-W. Every assertion states what the code does at the base of the phase. A later lane flips
// an assertion only where its decision in docs/plans/2026-10-11-phase-2-8.md says so. "BIO T5" in a doc comment is
// row T5 of the bioinformatics expert's inventory of the TaxTriage record for that phase, and the comment states the
// fact in full.
//
// No Nextflow, container or network is involved. `TaxTriageSerialBatchRunner(runPipeline:)` takes a stand-in
// for the engine, so the root record the runner writes is the product's own. The record a single run writes
// for itself is built from `TaxTriagePipeline.provenanceParameters` and `recordReadSetSteps`, the two
// helpers the run calls. What the run does between them (the TaxTriage step with the argv that ran, the
// removal of the split halves) needs the engine, and the stand-in engine of lane TF-G pins it later.

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

    private actor SeenConfigs {
        private(set) var configs: [TaxTriageConfig] = []
        func add(_ config: TaxTriageConfig) { configs.append(config) }
    }

    /// The runner with a stand-in for the engine. The stand-in writes `files` (sample-relative templates) into the
    /// sample's folder, answers a result that lists them all as the real run lists what is on disk, and throws for
    /// the sample ids in `failing`. `ignored` are the task failures Nextflow ignored for a sample.
    private func runner(
        _ seen: SeenConfigs,
        files: [String] = TaxTriageRecordFreezeTests.keptByTheRecord,
        failing: Set<String> = [],
        ignored: [String: [TaxTriageIgnoredFailure]] = [:]
    ) -> TaxTriageSerialBatchRunner {
        TaxTriageSerialBatchRunner(runPipeline: { sampleConfig, _ in
            await seen.add(sampleConfig)
            let id = sampleConfig.samples[0].sampleId
            if failing.contains(id) {
                throw NSError(domain: "TaxTriageRecordFreezeTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "synthetic failure of \(id)"])
            }
            let urls = try TaxTriageRecordFreezeTests.write(
                TaxTriageRecordFreezeTests.paths(files, for: id),
                in: sampleConfig.outputDirectory
            )
            return TaxTriageResult(
                config: sampleConfig,
                runtime: 1.5,
                exitCode: 0,
                outputDirectory: sampleConfig.outputDirectory,
                reportFiles: urls.filter { $0.lastPathComponent.hasSuffix(".odr.txt") },
                allOutputFiles: urls,
                ignoredFailures: ignored[id] ?? []
            )
        })
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

    private func relativeSet(_ descriptors: [ProvenanceFileDescriptor], to directory: URL) -> [String] {
        descriptors.map { relative($0.path, to: directory) }.sorted()
    }

    private func sampleSteps(_ envelope: ProvenanceEnvelope) -> [ProvenanceStep] {
        envelope.steps.filter { $0.toolName == "taxtriage" }
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

    // MARK: - BIO T2, where a run goes

    /// BIO T2. One sample runs straight into the output folder and the runner writes nothing of its own, so the
    /// record of that run is the one `TaxTriagePipeline.run` writes.
    func testASingleSampleRunsStraightIntoTheOutputFolderAndTheRunnerWritesNothing() async throws {
        let seen = SeenConfigs()
        let single = config([sample("Alpha")], bundles: [URL(fileURLWithPath: "/data/Alpha.lungfishfastq")])

        let result = try await runner(seen, files: []).run(config: single)

        let configs = await seen.configs
        XCTAssertEqual(configs, [single], "the engine gets the config as it was given, in the output folder itself")
        XCTAssertEqual(result.outputDirectory, single.outputDirectory)
        for name in [ProvenanceRecorder.provenanceFilename, "taxtriage-result.json"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: single.outputDirectory.appendingPathComponent(name).path),
                "the runner writes no \(name) for one sample"
            )
        }
    }

    /// BIO T2. Several samples run one Nextflow each, into a folder of the root named for the sample, and the runner
    /// writes the root record and the aggregate result. A sample id is made into a folder name, so `S 2` is `S_2`.
    func testSeveralSamplesRunOneEachIntoAFolderOfTheRootAndTheRunnerWritesTheBatchRecord() async throws {
        let seen = SeenConfigs()
        let bundles = ["Alpha", "S 2", "Gamma"].map { URL(fileURLWithPath: "/data/\($0).lungfishfastq") }
        let batch = config(["Alpha", "S 2", "Gamma"].map(sample), bundles: bundles)

        let result = try await runner(seen, files: ["report/x.odr.txt"]).run(config: batch)

        let configs = await seen.configs
        XCTAssertEqual(configs.map { $0.samples.map(\.sampleId) }, [["Alpha"], ["S 2"], ["Gamma"]], "one engine run per sample, in order")
        XCTAssertEqual(configs.map { $0.outputDirectory.lastPathComponent }, ["Alpha", "S_2", "Gamma"])
        XCTAssertEqual(
            configs.map { $0.outputDirectory.deletingLastPathComponent().standardizedFileURL },
            [batchRoot.standardizedFileURL, batchRoot.standardizedFileURL, batchRoot.standardizedFileURL]
        )
        XCTAssertEqual(configs.map { $0.sourceBundleURLs ?? [] }, bundles.map { [$0] }, "each run names its own bundle")
        XCTAssertEqual(result.outputDirectory, batchRoot)
        for name in [ProvenanceRecorder.provenanceFilename, "taxtriage-result.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(try record(in: batchRoot).workflowName, "TaxTriage Serial Batch")
    }

    // MARK: - BIO T3 and T4, the command and the tool

    /// BIO T3. The root record holds a `taxtriage` step per sample whose argv the runner rebuilds as `nextflow run ...`
    /// from the config. It is not the argv that ran, which is the managed micromamba path and its arguments and carries
    /// `-c`, `-with-trace` and `-w` (the sample's own record holds that one). The sample's folder is `--outdir`.
    func testTheBatchRecordHoldsOneRebuiltNextflowCommandPerSample() async throws {
        let batch = config([sample("Alpha"), sample("Beta")], everySetting: true)

        _ = try await runner(SeenConfigs(), files: []).run(config: batch)

        let envelope = try record(in: batchRoot)
        let steps = sampleSteps(envelope)
        XCTAssertEqual(steps.count, 2)
        for (step, id) in zip(steps, ["Alpha", "Beta"]) {
            let folder = batchRoot.appendingPathComponent(id, isDirectory: true).path
            XCTAssertEqual(step.argv, [
                "nextflow", "run", TaxTriageConfig.pipelineRepository, "-r", batch.revision, "-profile", "docker",
                "--input", folder + "/samplesheet.csv", "--outdir", folder, "--db", "/db/viral-kraken2",
                "--top_hits_count", "7", "--k2_confidence", "0.3", "--rank", "G", "--max_memory", "8.GB", "--max_cpus", "4",
                "--skip_assembly", "--skip_krona", "--remove_taxids", "9606 10090", "--foo", "bar",
            ], id)
            XCTAssertNil(step.durableReplayArgv)
            for launchOnly in ["-c", "-with-trace", "-w"] {
                XCTAssertFalse(step.argv.contains(launchOnly), "the rebuilt command lacks \(launchOnly), which the launch carries")
            }
        }
        let launch = TaxTriagePipeline().buildNextflowArguments(config: batch)
        XCTAssertTrue(launch.contains("-with-trace"), "the launch arguments carry what the rebuilt command lacks")
        let last = try XCTUnwrap(envelope.steps.last)
        XCTAssertEqual(last.toolName, "lungfish-app-taxtriage-serial-batch")
        XCTAssertEqual(last.argv, ["lungfish-app", "taxtriage-serial-batch", "--output", batchRoot.path])
        XCTAssertEqual(last.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(relativeSet(last.outputs, to: batchRoot), ["taxtriage-result.json"])
    }

    /// BIO T4. The batch record names the tool `taxtriage` and its version is the revision, a commit, with the release
    /// tag beside it. The sample's own record names the tool `TaxTriage` and holds the same two values (not reachable
    /// without the engine). No step or option holds the Nextflow version.
    func testTheSampleStepsNameTheToolTaxtriageAtTheRevisionWithTheReleaseTagBeside() async throws {
        let batch = config([sample("Alpha"), sample("Beta")])

        _ = try await runner(SeenConfigs(), files: []).run(config: batch)

        let envelope = try record(in: batchRoot)
        let revision = TaxTriageConfig.defaultRevision
        XCTAssertEqual(batch.revision, revision)
        XCTAssertEqual(revision.count, 40, "the revision is a commit")
        XCTAssertTrue(revision.allSatisfy(\.isHexDigit), revision)
        let tag = try XCTUnwrap(TaxTriageConfig.githubReleaseVersion(for: revision))
        XCTAssertTrue(tag.hasPrefix("v"), "the release tag is beside the revision, it is not the version: \(tag)")
        for step in sampleSteps(envelope) {
            XCTAssertEqual(step.toolVersion, revision)
            XCTAssertEqual(step.githubReleaseVersion, tag)
        }
        XCTAssertEqual(envelope.toolName, "taxtriage")
        XCTAssertEqual(envelope.toolVersion, revision)
        XCTAssertEqual(envelope.githubReleaseVersion, tag)
        XCTAssertEqual(envelope.options.explicit["revision"], .string(revision))
        XCTAssertEqual(envelope.options.explicit["github_release_version"], .string(tag))
        XCTAssertFalse(
            String(describing: envelope.options.explicit).lowercased().contains("nextflow"),
            "no option holds a Nextflow version"
        )
    }

    // MARK: - BIO T5, a failed sample

    /// BIO T5. A sample whose run throws is a step with exit 1, no outputs and the error as stderr, and the batch
    /// ends `completed` while any sample completed. The result lists the failure.
    func testAFailedSampleIsAStepWithExitOneAndNoOutputsAndTheBatchStillCompletes() async throws {
        let batch = config(["GoodA", "Bad", "GoodB"].map(sample))

        let result = try await runner(SeenConfigs(), files: ["report/x.odr.txt"], failing: ["Bad"]).run(config: batch)

        let envelope = try record(in: batchRoot)
        let steps = sampleSteps(envelope)
        XCTAssertEqual(steps.map(\.exitStatus), [0, 1, 0])
        XCTAssertEqual(steps.map { $0.outputs.isEmpty }, [false, true, false])
        XCTAssertEqual(steps[1].stderr, "synthetic failure of Bad")
        XCTAssertEqual(steps[1].argv.first, "nextflow", "a failed sample's command is rebuilt the same way")
        let outdir = try XCTUnwrap(steps[1].argv.firstIndex(of: "--outdir"))
        XCTAssertEqual(steps[1].argv[outdir + 1], batchRoot.appendingPathComponent("Bad").path)
        XCTAssertEqual(envelope.status, .completed)
        XCTAssertEqual(result.sampleFailures.map(\.sampleID), ["Bad"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try TaxTriageResult.load(from: batchRoot).sampleFailures.map(\.errorDescription), ["synthetic failure of Bad"])
    }

    /// BIO T5. When every sample fails, the batch throws, the record ends `failed` with every step at exit 1, and no
    /// aggregate result is written.
    func testWhenEverySampleFailsTheBatchThrowsAndTheRecordEndsFailed() async throws {
        let batch = config(["A", "B"].map(sample))

        do {
            _ = try await runner(SeenConfigs(), failing: ["A", "B"]).run(config: batch)
            XCTFail("the batch must throw when no sample completed")
        } catch let error as TaxTriageSerialBatchError {
            guard case .allSamplesFailed(let failures) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failures.map(\.sampleID), ["A", "B"])
        }

        let envelope = try record(in: batchRoot)
        XCTAssertEqual(envelope.status, .failed)
        XCTAssertEqual(envelope.steps.map(\.exitStatus), [1, 1])
        XCTAssertEqual(envelope.steps.map(\.toolName), ["taxtriage", "taxtriage"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent("taxtriage-result.json").path))
    }

    // MARK: - BIO T6 and T7, the run parameters and the plan

    private static let settingKeys: Set<String> = [
        "workflow", "sample_count", "platform", "classifiers", "top_hits_count", "k2_confidence", "rank",
        "skip_assembly", "skip_krona", "max_memory", "max_cpus", "profile", "revision", "extraArgs",
        "output_directory", "remove_taxids",
    ]

    /// BIO T6. A run's parameters hold the sixteen settings and the release version, the ids of the samples split to
    /// R1 and R2 when there are any, and `read_set_plans` when a plan has something to say. Nothing names the Kraken 2
    /// database, the Nextflow version or a container image, so a result cannot say which database classified it
    /// outside the argv of the engine's own step. Lane B2 records more of this as values, and the exact key sets
    /// below change with it.
    func testTheRunParametersHoldSixteenSettingsAndTheReleaseTag() throws {
        XCTAssertEqual(Self.settingKeys.count, 16)
        let c = config([sample("A")], everySetting: true)
        let pipeline = TaxTriagePipeline()

        let parameters = pipeline.provenanceParameters(for: c)

        XCTAssertEqual(Set(parameters.keys), Self.settingKeys.union(["github_release_version"]))
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
        XCTAssertEqual(parameters["revision"], .string(c.revision))
        XCTAssertEqual(parameters["extraArgs"], .string("--foo bar"))
        XCTAssertEqual(parameters["output_directory"], .file(c.outputDirectory))
        XCTAssertEqual(parameters["remove_taxids"], .string("9606 10090"))
        XCTAssertEqual(parameters["github_release_version"], .string(TaxTriageConfig.defaultGithubReleaseVersion))
        XCTAssertFalse(String(describing: parameters).contains("viral-kraken2"), "the database named in the config is in no parameter")

        let split = TaxTriagePipeline.InterleavedSampleSplit(
            sampleId: "A",
            source: URL(fileURLWithPath: "/data/A.fastq"),
            r1: URL(fileURLWithPath: "/scratch/A/R1.fastq"),
            r2: URL(fileURLWithPath: "/scratch/A/R2.fastq"),
            pairCount: 2,
            wallTime: 0
        )
        let withSplit = pipeline.provenanceParameters(for: c, interleavedSplits: [split])
        XCTAssertEqual(Set(withSplit.keys), Self.settingKeys.union(["github_release_version", "interleaved_samples_split_to_r1_r2"]))
        XCTAssertEqual(withSplit["interleaved_samples_split_to_r1_r2"], .array([.string("A")]))
    }

    /// BIO T6. The batch record holds the same sixteen settings and the release tag as options, under the workflow
    /// `taxtriage-serial-batch`. It holds no plan and no split, because each sample's own record holds those.
    func testTheBatchRecordHoldsTheSameSettingsAndNoPlan() async throws {
        let fixtures = try makeFixtures()
        let mixed = try await planned(fixtures.mixedRoot, as: "mixed", in: fixtures)
        let batch = config([mixed, sample("B")], everySetting: true)

        _ = try await runner(SeenConfigs(), files: []).run(config: batch)

        let options = try record(in: batchRoot).options.explicit
        XCTAssertEqual(Set(options.keys), Self.settingKeys.union(["github_release_version"]))
        XCTAssertEqual(options["workflow"], .string("taxtriage-serial-batch"))
        XCTAssertEqual(options["sample_count"], .integer(2))
        XCTAssertNotNil(mixed.readSetPlan?.provenanceParameters["readSetPlan"], "the first sample has a plan to record")
        XCTAssertNil(options["read_set_plans"], "the plan is not in the batch record")
        XCTAssertFalse(String(describing: options).contains("viral-kraken2"))
    }

    /// Saves a run holding `parameters` as the recorder does for a TaxTriage run and reads the record back.
    private func savedRecord(parameters: [String: ParameterValue], as name: String) async throws -> ProvenanceEnvelope {
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage", parameters: parameters)
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ProvenanceRecorder.shared.save(runID: runID, to: directory)
        return try record(in: directory)
    }

    /// BIO T7. A plan is recorded as `read_set_plans`, keyed by sample id, among the run parameters, and the recorder
    /// merges the run parameters into `options.explicit`. The one reader of a plan looks for `readSetPlan` only, so it
    /// never finds a TaxTriage plan, while it finds the same fields once they sit under that key. Each sample of a
    /// several-sample app run writes a record of one sample, so its dictionary holds one key.
    /// Plan decision T7 moves the plan of a record of one sample to `resolvedDefaults.readSetPlan` and lets the reader
    /// accept `read_set_plans[<sample>]`. Lane B2 flips the assertions marked FLIPS, on the record of one sample, and a
    /// pooled record of several samples keeps the keyed form.
    func testPlansAreKeyedBySampleInTheExplicitOptionsAndTheReaderNeverFindsThem() async throws {
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
        XCTAssertEqual(Set(try XCTUnwrap(pooled.options.explicit["read_set_plans"]?.dictionaryValue).keys), ["mixed", "merged"])
        XCTAssertNil(pooled.readSetPlan, "a pooled record of several samples keeps the keyed form, which the reader does not read")

        let oneSample = TaxTriagePipeline().provenanceParameters(for: config([mixed]))
        let single = try await savedRecord(parameters: oneSample, as: "single-record")
        XCTAssertEqual(Set(try XCTUnwrap(single.options.explicit["read_set_plans"]?.dictionaryValue).keys), ["mixed"])
        XCTAssertTrue(single.options.resolvedDefaults.isEmpty, "FLIPS: nothing is in the resolved defaults")
        XCTAssertNil(single.options.explicit["readSetPlan"])
        XCTAssertNil(single.readSetPlan, "FLIPS: the reader finds no TaxTriage plan")

        let underItsKey = single.with { copy in
            copy.options = ProvenanceOptions(
                explicit: copy.options.explicit,
                resolvedDefaults: ["readSetPlan": plans["mixed"]!]
            )
        }
        XCTAssertEqual(underItsKey.readSetPlan?.place, .resolvedDefaults)
        XCTAssertEqual(underItsKey.readSetPlan?.fields["capability"], .string("pairs_only_when_all_paired"))
    }

    // MARK: - BIO T8, T9 and T10, the files a record names that the run removes

    /// BIO T8. The split of an interleaved file into R1 and R2 is a step that names its source as the input, no
    /// outputs, and in its argv the folder of the halves, which is inside the run's scratch folder
    /// `.lungfish-interleaved-split`. The run removes that folder when it ends. The step and the run's files name the
    /// durable interleaved file, never a half as a file. (The TaxTriage step's own input list is not reachable without
    /// the engine.) Plan decision T6 keeps the halves scratch and has the record cite only the durable file, so the
    /// assertion on the folder in the argv may flip with lane B2.
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

        XCTAssertEqual(envelope.options.explicit["interleaved_samples_split_to_r1_r2"], .array([.string("inter")]))
        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(envelope.steps.count, 1)
        XCTAssertEqual(step.toolName, "Lungfish TaxTriage Interleaved Split")
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
    /// materialization. The batch record holds one `taxtriage` step per sample and the batch step and nothing between,
    /// and it names the materialized file where the bundle should be. The bundle appears only in the result file
    /// `taxtriage-result.json`, which the sidebar reads, never in the record.
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

        _ = try await runner(SeenConfigs(), files: []).run(config: config([a, b], bundles: bundles))

        let envelope = try record(in: batchRoot)
        XCTAssertEqual(envelope.steps.map(\.toolName), ["taxtriage", "taxtriage", "lungfish-app-taxtriage-serial-batch"])
        let text = try String(contentsOf: batchRoot.appendingPathComponent(ProvenanceRecorder.provenanceFilename), encoding: .utf8)
        for bundle in bundles {
            XCTAssertFalse(text.contains(bundle.deletingPathExtension().lastPathComponent), "the record names no bundle")
        }
        XCTAssertEqual(try TaxTriageResult.load(from: batchRoot).sourceBundleURLs, bundles, "only the result file names them")
    }

    /// BIO T10. The record names the materialized input files, with their digests, and the caller removes the folder
    /// they were written into when the run ends (the GUI in a `defer` of its TaxTriage launch in
    /// `AppDelegate+Classification`, the CLI route in `<output>/.lungfish-taxtriage-inputs`). The test removes it the same way, and the record then names
    /// files that no longer exist.
    func testTheRecordNamesMaterializedInputsThatTheCallerThenRemoves() async throws {
        let fixtures = try makeFixtures()
        let materialized = root.appendingPathComponent("materialized-inputs", isDirectory: true)
        let a = try await planned(fixtures.subsetOfSingle, as: "A", in: fixtures, materializeInto: materialized)
        let b = try await planned(fixtures.subsetOfInterleaved, as: "B", in: fixtures, materializeInto: materialized)
        let names = [a.fastq1, b.fastq1].map { relative($0.path, to: materialized) }
        for (file, name) in zip([a.fastq1, b.fastq1], names) {
            XCTAssertNotEqual(name, file.standardizedFileURL.path, "written inside the folder the caller named")
        }

        _ = try await runner(SeenConfigs(), files: []).run(config: config([a, b]))

        let envelope = try record(in: batchRoot)
        let inputs = sampleSteps(envelope).map(\.inputs)
        XCTAssertEqual(inputs.map { $0.map { relative($0.path, to: materialized) } }, names.map { [$0] })
        XCTAssertTrue(inputs.joined().allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil }, "recorded with a digest while the files exist")
        XCTAssertEqual(relativeSet(envelope.steps.last?.inputs ?? [], to: materialized), names.sorted())

        try FileManager.default.removeItem(at: materialized)

        let reread = try record(in: batchRoot)
        let namedNow = reread.steps.flatMap(\.inputs).map(\.path)
        XCTAssertEqual(namedNow.count, 4, "two samples, named by their step and by the batch step")
        XCTAssertTrue(namedNow.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "every input the record names is gone")
    }

    // MARK: - BIO T11, the files a record names

    /// BIO T11. A sample's step names every file of its result folder except those under `work`, `download` and
    /// `workflow-source`, so it names `count/`, the fastp FASTQ and the other folders that `build-db taxtriage` removes
    /// afterwards (see `BuildDbTaxTriageCleanupFreezeTests`). The batch result and the batch record's last step name the
    /// same files, and the last step names only `taxtriage-result.json` as an output.
    func testTheRecordNamesEveryOutputFileExceptWorkDownloadAndWorkflowSource() async throws {
        XCTAssertEqual(TaxTriageOutputArtifactPolicy.prunableDirectoryNames, ["work", "download", "workflow-source"])
        let files = Self.keptByTheRecord + Self.prunedFromTheRecord
        let batch = config(["A", "B"].map(sample))

        let result = try await runner(SeenConfigs(), files: files).run(config: batch)

        let envelope = try record(in: batchRoot)
        let steps = sampleSteps(envelope)
        for (step, id) in zip(steps, ["A", "B"]) {
            let folder = batchRoot.appendingPathComponent(id, isDirectory: true)
            XCTAssertEqual(relativeSet(step.outputs, to: folder), Self.paths(Self.keptByTheRecord, for: id).sorted(), id)
        }
        let expected = (["A", "B"].flatMap { id in Self.paths(Self.keptByTheRecord, for: id).map { "\(id)/\($0)" } } + ["taxtriage-result.json"]).sorted()
        XCTAssertEqual(result.allOutputFiles.map { relative($0.path, to: batchRoot) }, expected, "sorted by path, as the runner sorts")
        XCTAssertEqual(envelope.steps.last?.outputs.count, 1)
        // The rule is by path component below the output folder, wherever the component sits.
        let policy = TaxTriageOutputArtifactPolicy.self
        XCTAssertFalse(policy.isRetainedOutputFile(batchRoot.appendingPathComponent("A/report/work/x.tsv"), outputDirectory: batchRoot))
        XCTAssertTrue(policy.isRetainedOutputFile(batchRoot.appendingPathComponent("A/count/x.fastq.gz"), outputDirectory: batchRoot))
    }

    // MARK: - BIO T14, an ignored task failure

    /// BIO T14. Nextflow exits 0 when TaxTriage ignores an errored task. The failure is in `taxtriage-result.json`
    /// and in the GUI log, while the sample's step has exit 0 and no stderr, the failure text appears nowhere in the
    /// record, and the run is `completed`. Plan decision T8 keeps the run `completed`. If lane B2 puts the failures into
    /// the record, the assertions on stderr and on the record text flip.
    func testAnIgnoredTaskFailureLeavesExitZeroEmptyStderrAndACompletedRun() async throws {
        let failure = TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN",
            processName: "MINIMAP2_ALIGN",
            taskLabel: "A.MINIMAP2_ALIGN (A)",
            sampleID: "A",
            exitCode: 137,
            attempts: 3,
            diagnostic: "Killed: minimap2 -ax sr -t 14"
        )

        let result = try await runner(SeenConfigs(), files: ["report/x.odr.txt"], ignored: ["A": [failure]])
            .run(config: config(["A", "B"].map(sample)))

        XCTAssertEqual(result.ignoredFailures, [failure])
        XCTAssertEqual(try TaxTriageResult.load(from: batchRoot).ignoredFailures, [failure])
        let envelope = try record(in: batchRoot)
        let steps = sampleSteps(envelope)
        XCTAssertEqual(steps.map(\.exitStatus), [0, 0])
        XCTAssertTrue(steps.allSatisfy { ($0.stderr ?? "").isEmpty }, "the ignored failure is not the step's stderr")
        XCTAssertEqual(envelope.status, .completed)
        let text = try String(contentsOf: batchRoot.appendingPathComponent(ProvenanceRecorder.provenanceFilename), encoding: .utf8)
        for word in ["MINIMAP2_ALIGN", "Killed"] {
            XCTAssertFalse(text.contains(word), "the record does not hold \(word)")
        }
    }
}
