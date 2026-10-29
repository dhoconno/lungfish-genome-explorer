// TaxTriageSampleRecordFreezeTests.swift - What one TaxTriage run records for itself, run on the stand-in engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane B2, milestone M0. `TaxTriageRecordFreezeTests` (lane TF-W) pins the record the serial batch runner
// writes and the halves of a sample's record that two helpers build. `TaxTriagePipeline.run` saves the sample's own
// record around the engine, and builds its TaxTriage step in a function of its own, so these tests run the pipeline
// on `TaxTriageStandInEngine` (lane TF-G) and read the record it saved. They pin the seven per-sample facts of the
// TF-W review, BIO T3, T4, T6 to T8, T10, T11 and T14 of the bioinformatics inventory, and state today's facts.
// Lane B2 flips the assertions its decisions change, each marked FLIPS and named in the commit that flips it.
//
// No Nextflow, container or network is involved. Each test runs one pipeline on its own engine, whose home holds no
// cached TaxTriage asset, so the launch takes the `jhuapl-bio/taxtriage -r <revision>` form. The form that runs a
// cached asset from `workflow-source/taxtriage` without `-r` needs a git repository in the engine's home and is not
// pinned here.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageSampleRecordFreezeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-sample-record")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Helpers

    /// The sixteen settings every TaxTriage run records (BIO T6).
    static let settingKeys: Set<String> = [
        "workflow", "sample_count", "platform", "classifiers", "top_hits_count", "k2_confidence", "rank",
        "skip_assembly", "skip_krona", "max_memory", "max_cpus", "profile", "revision", "extraArgs",
        "output_directory", "remove_taxids",
    ]

    /// The settings a record keeps among its explicit options. Moved by B11 M2 (R5): `classifiers` is a resolved
    /// default, because the launch passes no `--classifiers`. Moved by A2 M3 (B12 ruling H1): `sample_count` is a
    /// resolved default, because LGE counts the samplesheet rows itself.
    static let explicitSettingKeys = settingKeys.subtracting(["classifiers", "sample_count"])

    private func makeEngine(_ behaviour: TaxTriageStandInEngine.Behaviour = .completes) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), behaviour: behaviour)
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// A Kraken 2 database folder with its three core files, which the stand-in never reads.
    private func makeDatabase() throws -> URL {
        let folder = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, bytes) in [("hash.k2d", 11), ("opts.k2d", 7), ("taxo.k2d", 5)] {
            try Data(repeating: 0x2A, count: bytes).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    /// A FASTQ of `records` records whose names never pair, so it reads as single reads.
    private func writeFASTQ(_ name: String, records: Int) throws -> URL {
        let folder = root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let text = (1...records).map { "@\(stem)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func config(_ sample: TaxTriageSample, output: String, database: URL) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: [sample],
            outputDirectory: root.appendingPathComponent(output, isDirectory: true),
            kraken2DatabasePath: database,
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile
        )
    }

    /// A sample planned from a read set fixture bundle as the app and `taxtriage run` plan it, with the files the
    /// planner writes kept in `inputs`, a folder no caller removes here.
    private func planned(_ bundle: URL, as id: String, in fixtures: ReadSetFixtures) async throws -> TaxTriageSample {
        try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: id, fastq1: bundle),
            materializationDirectory: root.appendingPathComponent("inputs", isDirectory: true),
            materializer: fixtures.materializer
        )
    }

    private struct Run {
        let result: TaxTriageResult
        let record: ProvenanceEnvelope
        let launch: TaxTriageStandInEngine.Launch
        let output: URL
    }

    /// Runs the pipeline on `engine` and reads back the record it saved in the output folder.
    private func run(_ config: TaxTriageConfig, on engine: TaxTriageStandInEngine) async throws -> Run {
        let result = try await engine.makePipeline().run(config: config)
        let record = try XCTUnwrap(
            ProvenanceEnvelopeReader.loadCanonical(from: config.outputDirectory),
            "no record in \(config.outputDirectory.path)"
        )
        let launches = try engine.launches()
        XCTAssertEqual(launches.count, 1, "one run launches the engine once")
        return Run(result: result, record: record, launch: try XCTUnwrap(launches.first), output: config.outputDirectory)
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

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Every path a descriptor of the record names, in its steps and at run level.
    private func namedPaths(_ record: ProvenanceEnvelope) -> [String] {
        (record.steps.flatMap { $0.inputs + $0.outputs } + record.files + record.outputs).map(\.path)
    }

    private func taxTriageStep(_ record: ProvenanceEnvelope) throws -> ProvenanceStep {
        try XCTUnwrap(record.steps.last, "the TaxTriage step is the last step")
    }

    // MARK: - BIO T3, T4 and T11, a plain sample

    /// BIO T3, T4 and T11. A sample of one file of single reads records one step, the TaxTriage step, whose argv is
    /// the one that launched the engine, the managed micromamba with `run -n nextflow nextflow` and the Nextflow
    /// arguments with `-c`, `-with-trace` and `-w`, and no durable argv. Its tool is `taxtriage` (RT4, flipped by B2)
    /// at the revision with the release tag beside it, and as the first step it names the record's tool. Its outputs
    /// are every file of the result folder except `work`, `download` and `workflow-source`, which the run prunes, plus
    /// `taxtriage-result.json`, each an existing file with its digest, `count/` and the fastp FASTQ among them. Its
    /// resolved defaults name the Kraken 2 database as E9 does, and the step's resolved options the Nextflow that ran
    /// (RT5, added by B2).
    func testAPlainSampleRecordsTheArgvThatRanAsItsOneStep() async throws {
        let engine = try makeEngine()
        let reads = try writeFASTQ("S1.fastq", records: 7)
        let database = try makeDatabase()
        let c = config(TaxTriageSample(sampleId: "S1", fastq1: reads), output: "plain", database: database)
        // TaxTriage writes raw read copies to count/ and trimmed reads to fastp/, which the stand-in does not.
        for seeded in ["count/S1.fastq.gz", "fastp/S1.fastp.fastq.gz", "download/S1.dwnld.references.fasta", "work/ab/cd1234/.command.sh"] {
            let url = c.outputDirectory.appendingPathComponent(seeded)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(seeded)\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let run = try await run(c, on: engine)

        let record = run.record
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.steps.count, 1)
        let step = try taxTriageStep(record)
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        let revision = pin.revision
        XCTAssertEqual(step.toolName, "taxtriage", "flipped by B2 (RT4), one tool name, as the batch record names it")
        XCTAssertEqual(step.toolVersion, revision, "the version is the revision, a commit")
        XCTAssertEqual(step.githubReleaseVersion, pin.releaseVersion)
        XCTAssertEqual(step.argv, [engine.micromamba.path, "run", "-n", "nextflow", "nextflow"] + run.launch.arguments)
        XCTAssertNil(step.durableReplayArgv)
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertTrue((step.stderr ?? "").isEmpty, "\(step.stderr ?? "")")
        XCTAssertEqual(record.toolName, "taxtriage", "flipped by B2 (RT4), the first step names the record's tool")
        XCTAssertEqual(record.toolVersion, revision)
        XCTAssertEqual(record.argv, step.argv)

        let arguments = run.launch.arguments
        XCTAssertFalse(arguments.contains("--classifiers"), "R5, the argv is unchanged and passes no classifiers")
        XCTAssertEqual(
            Array(arguments.prefix(6)),
            ["-c", run.output.appendingPathComponent("lungfish.nextflow.config").path, "run", pin.repository, "-r", revision]
        )
        XCTAssertEqual(run.launch.value(after: "-with-trace"), run.output.appendingPathComponent("trace.txt").path)
        let work = try XCTUnwrap(run.launch.value(after: "-w"))
        XCTAssertFalse(work.hasPrefix(run.output.path + "/"), "Nextflow works in the launch scratch, outside the result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work), "the run removes its launch scratch")

        XCTAssertEqual(step.inputs.map(\.path), [reads.path])
        XCTAssertTrue(step.inputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        let outputs = step.outputs.map { relative($0.path, to: run.output) }.sorted()
        XCTAssertEqual(outputs, [
            "combine/S1.combined.gcfmap.tsv", "count/S1.fastq.gz", "fastp/S1.fastp.fastq.gz", "lungfish.nextflow.config",
            "nextflow.log", "report/S1.odr.txt", "samplesheet.csv", "taxtriage-launch-command.sh",
            "taxtriage-launch-command.txt", "taxtriage-result.json", "top/S1.top_report.tsv", "trace.txt",
        ], "the files of the result the step names")
        XCTAssertTrue(step.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil }, "each with its digest")
        for pruned in ["download", "work"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: run.output.appendingPathComponent(pruned).path), pruned)
        }
        XCTAssertEqual(namedPaths(record).filter { !FileManager.default.fileExists(atPath: $0) }, [], "every named file exists")
        XCTAssertEqual(Set(record.options.explicit.keys), Self.explicitSettingKeys.union(["github_release_version"]))
        XCTAssertEqual(record.options.explicit["profile"], .string(TaxTriageStandInEngine.profile))
        // Flipped by B2 (RT5). The database is recorded as E9 records EsViritu's, among the resolved defaults, and the
        // TaxTriage step names the Nextflow that ran. Moved by B11 M2 (R5), `classifiers` joins the resolved defaults,
        // and moved by A2 M3 (B12 ruling H1), `sample_count` does too.
        let resolved = record.options.resolvedDefaults
        XCTAssertEqual(
            Set(resolved.keys),
            ["classifiers", "sample_count", "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes", "fetchedReferences"],
            "moved by A2 M3 (B12 ruling H1), sample_count is a resolved default"
        )
        XCTAssertEqual(resolved["classifiers"], .array([.string("kraken2")]))
        XCTAssertEqual(resolved["sample_count"], .integer(1), "B12 ruling H1")
        XCTAssertEqual(resolved["databasePath"]?.stringValue.map(standardized), standardized(database.path))
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertEqual(
            resolved["databaseCoreFileSizes"],
            .dictionary(["hash.k2d": .integer(11), "opts.k2d": .integer(7), "taxo.k2d": .integer(5)]),
            "the size of each core file, and nothing hashed"
        )
        // Moved by B11 M2 (T6). The step adds `pipelineSource`, `remote` because the engine's home holds no cached asset.
        XCTAssertEqual(
            step.resolvedOptions,
            ["nextflowVersion": .string("25.04.6"), "pipelineSource": .string("remote")],
            "the version from the banner the stand-in printed, and the branch that launched"
        )
    }

    // MARK: - BIO T6 and T8, an interleaved sample

    /// BIO T6 and T8. A strictly interleaved file runs as R1 and R2 halves that the run writes into
    /// `.lungfish-interleaved-split` and removes when it ends. The split step names the durable interleaved file as its
    /// input and no output, the TaxTriage step names the durable file with its digest, not the halves the engine read,
    /// and no descriptor of the record names a half. The split is the first step, so the record names it as its tool
    /// at the app version.
    func testAnInterleavedSampleRecordsTheDurableFileAndNoHalf() async throws {
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let sample = try await planned(fixtures.interleavedRoot, as: "inter", in: fixtures)
        XCTAssertEqual(sample.readLayout, .strictlyInterleaved)
        let c = config(sample, output: "interleaved", database: try makeDatabase())

        let run = try await run(c, on: engine)

        let splitRoot = run.output.appendingPathComponent(TaxTriagePipeline.interleavedSplitDirectoryName, isDirectory: true)
        XCTAssertEqual(run.launch.fastqRecords.map(\.column), ["fastq_1", "fastq_2"], "the engine read two halves")
        for half in run.launch.fastqRecords {
            XCTAssertTrue(half.path.hasPrefix(splitRoot.path + "/"), half.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: splitRoot.path), "the run removes the halves")

        let record = run.record
        XCTAssertEqual(record.steps.map(\.toolName), ["Lungfish TaxTriage Interleaved Split", "taxtriage"])
        let split = record.steps[0]
        XCTAssertEqual(split.inputs.map { standardized($0.path) }, [standardized(sample.fastq1.path)])
        XCTAssertEqual(split.outputs.count, 0)
        let step = try taxTriageStep(record)
        XCTAssertEqual(step.inputs.map { standardized($0.path) }, [standardized(sample.fastq1.path)], "the durable file")
        XCTAssertTrue(step.inputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        let named = namedPaths(record).map(standardized)
        XCTAssertFalse(named.contains { $0.contains("/" + TaxTriagePipeline.interleavedSplitDirectoryName + "/") }, "no half is named")
        XCTAssertEqual(namedPaths(record).filter { !FileManager.default.fileExists(atPath: $0) }, [], "every named file exists")
        XCTAssertEqual(record.toolName, "Lungfish TaxTriage Interleaved Split", "the first step names the record's tool")
        XCTAssertEqual(record.toolVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(record.options.resolvedDefaults["interleaved_samples_split_to_r1_r2"], .array([.string("inter")]))
        XCTAssertNil(record.options.explicit["interleaved_samples_split_to_r1_r2"], "B12 ruling H2")
    }

    // MARK: - BIO T6, T7 and T10, a joined and a materialized sample

    /// BIO T10. A bundle of several files of single reads runs as one file that the planner joined with `cat` into the
    /// folder its caller named. The `cat` step names the bundle's files and the joined file, and the TaxTriage step
    /// names the joined file with its digest. The `cat` step is the first step, so the record names it as its tool.
    func testAJoinedSampleRecordsTheCatStepAndTheJoinedFile() async throws {
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let sample = try await planned(fixtures.chunkedRoot, as: "joined", in: fixtures)
        let concatenation = try XCTUnwrap(SequenceInputConcatenation.load(for: sample.fastq1), "the planner joined the bundle")
        let c = config(sample, output: "joined", database: try makeDatabase())

        let run = try await run(c, on: engine)

        let record = run.record
        XCTAssertEqual(record.steps.map(\.toolName), [SequenceInputConcatenation.toolName, "taxtriage"])
        let cat = record.steps[0]
        XCTAssertEqual(cat.inputs.map { standardized($0.path) }, concatenation.memberURLs.map { standardized($0.path) })
        XCTAssertEqual(cat.outputs.map { standardized($0.path) }, [standardized(sample.fastq1.path)])
        let step = try taxTriageStep(record)
        XCTAssertEqual(step.inputs.map { standardized($0.path) }, [standardized(sample.fastq1.path)], "the joined file")
        XCTAssertTrue(step.inputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertEqual(namedPaths(record).filter { !FileManager.default.fileExists(atPath: $0) }, [], "every named file exists")
        XCTAssertEqual(record.toolName, SequenceInputConcatenation.toolName, "the first step names the record's tool")
        XCTAssertEqual(record.toolVersion, WorkflowRun.currentAppVersion)
    }

    /// BIO T7. A bundle that mixes pairs and single reads runs as single reads, and its plan says why. The record of
    /// one sample holds the plan as the resolved default `readSetPlan`, where the reader finds it, and keeps no keyed
    /// plan (decision T7, flipped by B2).
    func testAMixedSampleRecordsItsPlanAsTheResolvedDefault() async throws {
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let sample = try await planned(fixtures.mixedRoot, as: "mixed", in: fixtures)
        XCTAssertNotNil(sample.readSetPlan?.singleReadReason)
        let c = config(sample, output: "mixed", database: try makeDatabase())

        let run = try await run(c, on: engine)

        let record = run.record
        XCTAssertEqual(record.steps.map(\.toolName), ["taxtriage"])
        // Flipped by B2 (T7). The record of one sample keeps no keyed plan, and its plan is the resolved default
        // `readSetPlan`, where the reader finds it. Moved by B11 M2 (R5), `classifiers` is not explicit.
        XCTAssertEqual(Set(record.options.explicit.keys), Self.explicitSettingKeys.union(["github_release_version"]))
        let plan = try XCTUnwrap(sample.readSetPlan?.provenanceParameters["readSetPlan"])
        XCTAssertEqual(record.options.resolvedDefaults["readSetPlan"], plan)
        XCTAssertEqual(record.readSetPlan?.place, .resolvedDefaults)
        XCTAssertEqual(record.readSetPlan?.fields["capability"], .string("pairs_only_when_all_paired"))
        XCTAssertEqual(record.readSetPlan?.fields["singleReadReason"], .string(try XCTUnwrap(sample.readSetPlan?.singleReadReason)))
    }

    /// BIO T7. A pooled run of several samples, as `taxtriage run --output` runs them in one Nextflow, keeps each
    /// sample's plan keyed by the sample under `read_set_plans` in the explicit options, because one `readSetPlan`
    /// cannot hold several samples' plans, and its resolved defaults hold the database alone.
    func testAPooledRunKeepsItsPlansKeyedBySample() async throws {
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let mixed = try await planned(fixtures.mixedRoot, as: "mixed", in: fixtures)
        let plain = TaxTriageSample(sampleId: "plain", fastq1: try writeFASTQ("plain.fastq", records: 4))
        var c = config(mixed, output: "pooled", database: try makeDatabase())
        c.samples.append(plain)

        let run = try await run(c, on: engine)

        let record = run.record
        XCTAssertEqual(record.options.resolvedDefaults["sample_count"], .integer(2), "B12 ruling H1")
        XCTAssertNil(record.options.explicit["sample_count"], "B12 ruling H1")
        let plans = try XCTUnwrap(record.options.explicit["read_set_plans"]?.dictionaryValue)
        XCTAssertEqual(plans, ["mixed": try XCTUnwrap(mixed.readSetPlan?.provenanceParameters["readSetPlan"])])
        XCTAssertEqual(
            Set(record.options.resolvedDefaults.keys),
            ["classifiers", "sample_count", "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes", "fetchedReferences"],
            "moved by B11 M2 (R5), classifiers is a resolved default, and by A2 M3 (B12 ruling H1), sample_count"
        )
        XCTAssertNil(record.options.explicit["readSetPlan"])
    }

    /// BIO T9 and T10. A virtual bundle is materialized into the folder its caller named before TaxTriage reads it.
    /// The record names the materialized file with its digest as the TaxTriage step's input and records no step for
    /// the materialization.
    func testAMaterializedSampleRecordsTheMaterializedFileAndNoStepForIt() async throws {
        let engine = try makeEngine()
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let sample = try await planned(fixtures.subsetOfSingle, as: "virtual", in: fixtures)
        XCTAssertEqual(sample.readSetPlan?.wasMaterialized, true)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        XCTAssertTrue(sample.fastq1.standardizedFileURL.path.hasPrefix(inputs.standardizedFileURL.path + "/"), sample.fastq1.path)
        let c = config(sample, output: "materialized", database: try makeDatabase())

        let run = try await run(c, on: engine)

        let record = run.record
        XCTAssertEqual(record.steps.map(\.toolName), ["taxtriage"], "no step records the materialization")
        let step = try taxTriageStep(record)
        XCTAssertEqual(step.inputs.map { standardized($0.path) }, [standardized(sample.fastq1.path)], "the materialized file")
        XCTAssertTrue(step.inputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertEqual(namedPaths(record).filter { !FileManager.default.fileExists(atPath: $0) }, [], "every named file exists")
    }

    // MARK: - BIO T14, an ignored task failure

    /// BIO T14 and decision T8. When TaxTriage ignores a failed task, Nextflow exits 0 and the result lists the
    /// failure. The TaxTriage step has exit 0 and one warning line per ignored failure as its stderr, which the record
    /// repeats, and the record stays `completed` (flipped by B2).
    func testAnIgnoredTaskFailureLeavesExitZeroAWarningLineAndACompletedRecord() async throws {
        let engine = try makeEngine(.reportsErroredTasks)
        let reads = try writeFASTQ("S1.fastq", records: 3)
        let c = config(TaxTriageSample(sampleId: "S1", fastq1: reads), output: "errored", database: try makeDatabase())

        let run = try await run(c, on: engine)

        XCTAssertEqual(run.result.ignoredFailures.map(\.processName), ["MINIMAP2_ALIGN"])
        XCTAssertEqual(run.result.ignoredFailures.map(\.sampleID), ["S1"])
        XCTAssertEqual(run.result.ignoredFailures.map(\.exitCode), [137])
        let record = run.record
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.exitStatus, 0)
        let step = try taxTriageStep(record)
        XCTAssertEqual(step.exitStatus, 0)
        // Flipped by B2 (T8). One warning line per ignored failure is the step's stderr, and so the record's.
        let warnings = TaxTriageRecordFacts.warningLines(for: run.result.ignoredFailures)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(step.stderr, warnings.joined(separator: "\n"))
        XCTAssertEqual(record.stderr, step.stderr, "the record's stderr is its last step's")
        let line = try XCTUnwrap(warnings.first)
        XCTAssertTrue(line.hasPrefix("Warning: TaxTriage ignored the failure of "), line)
        for part in ["MINIMAP2_ALIGN", "for sample S1", "exit status 137"] {
            XCTAssertTrue(line.contains(part), "\(part) in \(line)")
        }
    }

    // MARK: - The facts as values

    /// Decision T8. A warning line names the process, the sample, the exit status, the attempts when there were
    /// several and the key line of the task's stderr, and a task Nextflow did not name still gives a line.
    func testAWarningLineNamesTheTaskItsSampleItsExitAndItsDiagnostic() {
        let named = TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN",
            processName: "MINIMAP2_ALIGN",
            taskLabel: "A.MINIMAP2_ALIGN (A)",
            sampleID: "A",
            exitCode: 137,
            attempts: 3,
            diagnostic: "Killed: minimap2 -ax sr -t 14"
        )
        let unnamed = TaxTriageIgnoredFailure(processPath: "", processName: "", taskLabel: "", sampleID: nil, exitCode: -1)

        XCTAssertEqual(TaxTriageRecordFacts.warningLines(for: [named, unnamed]), [
            "Warning: TaxTriage ignored the failure of NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN for sample A, exit status 137 after 3 attempts (Killed: minimap2 -ax sr -t 14)",
            "Warning: TaxTriage ignored the failure of a task Nextflow did not name, exit status -1",
        ])
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inLog: "Launching jhuapl-bio/taxtriage"))
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inLog: " N E X T F L O W  ~  version 24.10.4\n"), "24.10.4")
    }

    /// RT5. A database the app installed holds its install receipt, and its identity adds the catalog entry and the
    /// version that receipt names. A receipt that names another folder adds nothing.
    func testAnInstalledDatabaseAddsTheCatalogEntryItsReceiptNames() throws {
        let database = try makeDatabase()
        let fixture = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/provenance-compat/cases/s1-db-receipt-kraken2-viral/managed-storage/databases/kraken2/viral/.lungfish-provenance.json"
        )
        let receipt = try String(contentsOf: fixture, encoding: .utf8)
        // The receipt's JSON escapes each slash of a path.
        func escaped(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\/") }
        let original = escaped("/srv/corpus/.lungfish/databases/kraken2/viral")
        XCTAssertTrue(receipt.contains(original))
        let sidecar = database.appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        try receipt.replacingOccurrences(of: original, with: escaped(database.standardizedFileURL.path))
            .write(to: sidecar, atomically: true, encoding: .utf8)
        let identity = TaxTriageRecordFacts.databaseIdentity(at: database)
        XCTAssertEqual(identity["databaseCatalogID"], .string("kraken2-viral"))
        XCTAssertNotNil(identity["databaseCatalogVersion"]?.stringValue)
        XCTAssertEqual(identity["databaseIdentityStatus"], .string("pinned"), "a receipt that adds up pins the folder (DB-IDENTITY, 3.1)")
        XCTAssertNotNil(identity["databaseDigest"], "the digest the receipt states")

        try receipt.write(to: sidecar, atomically: true, encoding: .utf8)
        let elsewhere = TaxTriageRecordFacts.databaseIdentity(at: database)
        XCTAssertNil(elsewhere["databaseCatalogID"], "the receipt names another folder")
        XCTAssertEqual(Set(elsewhere.keys), ["databasePath", "databaseIdentityStatus", "databaseCoreFileSizes"])
    }

    /// RT5 and E9 (review fix 3). A receipt of an archive install names the source URL and the source policy, and the
    /// identity records both. A receipt that holds a placeholder for its catalog entry records no entry, and the
    /// version is the first of the requested catalog version and the receipt's workflow version that is not a
    /// placeholder. The save keeps every key of the identity among the record's resolved defaults.
    func testAReceiptAddsItsSourceAndNoPlaceholderCatalogEntry() throws {
        let database = try makeDatabase()
        let fixture = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/provenance-compat/cases/s1-db-receipt-kraken2-viral/managed-storage/databases/kraken2/viral/.lungfish-provenance.json"
        )
        var receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var options = try XCTUnwrap(receipt["options"] as? [String: Any])
        var explicit = try XCTUnwrap(options["explicit"] as? [String: Any])
        var resolved = try XCTUnwrap(options["resolvedDefaults"] as? [String: Any])
        func typed(_ value: String) -> [String: Any] { ["type": "string", "value": value] }
        let sourceURL = "https://genome-idx.s3.amazonaws.com/kraken/k2_viral_20240904.tar.gz"
        explicit["catalogID"] = typed("unknown")
        resolved["intendedFinalPath"] = typed(database.standardizedFileURL.path)
        resolved["requestedSourceURL"] = typed(sourceURL)
        resolved["databaseSourcePolicy"] = typed("unpinnedArchive")
        resolved["requestedCatalogVersion"] = typed("unspecified")
        options["explicit"] = explicit
        options["resolvedDefaults"] = resolved
        receipt["options"] = options
        try JSONSerialization.data(withJSONObject: receipt)
            .write(to: database.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        let identity = TaxTriageRecordFacts.databaseIdentity(at: database)
        XCTAssertEqual(identity["databaseSourceURL"], .string(sourceURL))
        XCTAssertEqual(identity["databaseSourcePolicy"], .string("unpinnedArchive"))
        XCTAssertNil(identity["databaseCatalogID"], "unknown is a placeholder, not a catalog entry")
        XCTAssertEqual(identity["databaseCatalogVersion"], .string("20260626"), "the first version that is not a placeholder")
        XCTAssertEqual(Set(identity.keys), [
            "databasePath", "databaseIdentityStatus", "databaseCoreFileSizes",
            "databaseSourceURL", "databaseSourcePolicy", "databaseCatalogVersion", "databaseIdentityNote",
        ])
        XCTAssertEqual(
            TaxTriageRecordFacts.recordOptions(fromRunParameters: identity).resolvedDefaults,
            identity,
            "the save files all seven keys among the resolved defaults"
        )
    }

    /// RT5 and E9 (follow-up review fix 1). The receipt of an install that ended with a failure adds nothing to the
    /// identity, so a record never names a catalog entry, a version or a source that the folder does not have. The
    /// receipt is the one the test before it writes, with its catalog entry and requested version as the fixture
    /// holds them, and with the top-level exit status 1.
    func testAReceiptOfAFailedInstallAddsNothingToTheIdentity() throws {
        let database = try makeDatabase()
        let fixture = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent(
            "Tests/Fixtures/provenance-compat/cases/s1-db-receipt-kraken2-viral/managed-storage/databases/kraken2/viral/.lungfish-provenance.json"
        )
        var receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var options = try XCTUnwrap(receipt["options"] as? [String: Any])
        var resolved = try XCTUnwrap(options["resolvedDefaults"] as? [String: Any])
        func typed(_ value: String) -> [String: Any] { ["type": "string", "value": value] }
        resolved["intendedFinalPath"] = typed(database.standardizedFileURL.path)
        resolved["requestedSourceURL"] = typed("https://genome-idx.s3.amazonaws.com/kraken/k2_viral_20240904.tar.gz")
        resolved["databaseSourcePolicy"] = typed("unpinnedArchive")
        options["resolvedDefaults"] = resolved
        receipt["options"] = options
        receipt["exitStatus"] = 1
        try JSONSerialization.data(withJSONObject: receipt)
            .write(to: database.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        XCTAssertEqual(
            ProvenanceRecorder.loadEnvelope(from: database)?.exitStatus,
            1,
            "the receipt loads with its failed status"
        )
        XCTAssertEqual(
            Set(TaxTriageRecordFacts.databaseIdentity(at: database).keys),
            ["databasePath", "databaseIdentityStatus", "databaseCoreFileSizes"],
            "a failed install names no catalog entry, version or source"
        )
    }

    /// RT2. A step of a sample's read set plan, a split or an interleave the resolver wrote, is recorded as Kraken 2
    /// records it, before the pipeline's own split and join steps, with its files and their digests.
    func testAStepOfTheReadSetPlanIsRecordedBeforeTheRunsOwnSteps() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let mixed = try await planned(fixtures.mixedRoot, as: "mixed", in: fixtures)
        let base = try XCTUnwrap(mixed.readSetPlan)
        let source = try writeFASTQ("mixed-source.fastq", records: 2)
        let written = try writeFASTQ("mixed-single.fastq", records: 2)
        let started = Date(timeIntervalSince1970: 1_000)
        let step = ReadSetStep(
            kind: .splitByName,
            inputURLs: [source],
            outputURLs: [written],
            pairCount: 0,
            singleReadCount: 2,
            startedAt: started,
            endedAt: started.addingTimeInterval(1.5)
        )
        var sample = mixed
        sample.readSetPlan = ReadSetPlan(
            inputURL: base.inputURL,
            capability: base.capability,
            sourceLayout: base.sourceLayout,
            layoutReason: base.layoutReason,
            sequencingPlatform: base.sequencingPlatform,
            wasMaterialized: base.wasMaterialized,
            sampleHoldsPairsAndSingleReads: base.sampleHoldsPairsAndSingleReads,
            runs: base.runs,
            steps: [step],
            singleReadReason: base.singleReadReason,
            composition: base.composition
        )

        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage")
        await TaxTriagePipeline.recordReadSetSteps(runID: runID, config: config(sample, output: "steps", database: try makeDatabase()), splits: [])
        let recorded = await ProvenanceRecorder.shared.canonicalEnvelope(for: runID)
        let envelope = try XCTUnwrap(recorded)

        let first = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(first.toolName, "Lungfish Read-Set Split")
        XCTAssertEqual(first.argv, step.command)
        XCTAssertEqual(first.resolvedOptions, ["sample": .string("mixed"), "pairs": .integer(0), "singleReads": .integer(2)])
        XCTAssertEqual(first.inputs.map(\.path), [source.path])
        XCTAssertEqual(first.outputs.map(\.path), [written.path])
        XCTAssertTrue((first.inputs + first.outputs).allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertEqual(first.wallTimeSeconds, 1.5)
    }
}
