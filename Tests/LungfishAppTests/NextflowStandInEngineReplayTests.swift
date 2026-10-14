// NextflowStandInEngineReplayTests.swift - The shared stand-in Nextflow on its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q9 M1, decision N11 (docs/plans/2026-10-12-phase-2-9.md). The five TaxTriage
// classes run the stand-in through today's pipeline. These cases launch it directly: the record
// numbers of launches at once, the line shapes of R1's real Nextflow 26.04.6 output, the 2.8 lines
// and the 25.04.6 sentinel, the engine options a launch records, and the pin that no support file
// imports a module for testing.

import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class NextflowStandInEngineReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-stand-in")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Record numbers

    /// Sixteen launches at once each take their own record. The 2.8 engine numbered a record by
    /// counting the folders and then creating one, so two launches at once could pick the same
    /// number, and the one that lost exited 70 with no record.
    func testLaunchesAtOnceTakeDistinctRecordNumbers() throws {
        let engine = try TaxTriageStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true))
        let sheet = try writeSamplesheet(["S1"])
        let count = 16
        let statuses = StatusTable(count: count)
        let nextflow = engine.nextflow
        let outputs = root.appendingPathComponent("outputs", isDirectory: true)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let output = outputs.appendingPathComponent("run-\(index)", isDirectory: true)
            let result = try? ProcessRunner.run(
                nextflow,
                ["run", "stand-in", "--input", sheet.path, "--outdir", output.path],
                timeout: 60
            )
            statuses.set(index, result?.status ?? -1)
        }

        XCTAssertEqual(statuses.values, Array(repeating: 0, count: count), "every launch exits 0")
        let launches = try engine.launches()
        XCTAssertEqual(launches.map(\.folder.lastPathComponent), (1...count).map { String(format: "%03d", $0) })
        XCTAssertEqual(launches.map(\.exitStatus), Array(repeating: 0, count: count))
    }

    // MARK: - Output modes

    /// A plain-log launch through `engineLaunch` prints only lines whose shape R1's real output
    /// has, the same 46 tasks as R1 for R1's two samples, in R1's order of line kinds, and the
    /// stand-in's version where R1 prints 26.04.6.
    func testPlainLogPrintsTheLineShapesOfRealNextflow2604() throws {
        let engine = try NextflowStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), workflow: .taxTriage)
        let launch = engine.engineLaunch
        XCTAssertTrue(launch.usesManagedExecutable, "the stand-in is the managed Nextflow of its home")
        XCTAssertEqual(launch.executableURL.standardizedFileURL, engine.nextflow.standardizedFileURL)
        XCTAssertEqual(launch.environment["HOME"], engine.home.path)
        XCTAssertEqual(launch.environment["MAMBA_ROOT_PREFIX"], engine.condaRoot.path)
        XCTAssertEqual(launch.environment["NXF_ANSI_LOG"], "false")

        let sheet = try writeSamplesheet(["SRR12486983", "SRR12486989"])
        let output = root.appendingPathComponent("output", isDirectory: true)
        let work = root.appendingPathComponent("scratch/work", isDirectory: true)
        let trace = output.appendingPathComponent("trace.txt")
        let snapshot = root.appendingPathComponent("output/workflow-source/taxtriage", isDirectory: true)
        let result = try launchDirectly(launch, [
            "-c", output.appendingPathComponent("lungfish.nextflow.config").path,
            "run", snapshot.path, "-profile", TaxTriageStandInEngine.profile,
            "--input", sheet.path, "--outdir", output.path, "-w", work.path, "-with-trace", trace.path,
        ])
        XCTAssertEqual(result.status, 0, result.stderr)

        let lines = result.stdout.split(separator: "\n").map(String.init)
        let excerpt = r1PlainLogExcerpt.split(separator: "\n").map(String.init)
        let excerptShapes = Set(excerpt.map(Self.shape))
        XCTAssertEqual(lines.map(Self.shape).filter { !excerptShapes.contains($0) }, [], "lines R1 has no shape for")
        let tasks = lines.filter { $0.hasPrefix("[PROCESS ") }.map(Self.shape).sorted()
        XCTAssertEqual(tasks, excerpt.filter { $0.hasPrefix("[PROCESS ") }.map(Self.shape).sorted())
        XCTAssertEqual(tasks.count, NextflowStandInWorkflow.taxTriage.taskCount(sampleCount: 2))
        XCTAssertEqual(Self.kindOrder(of: lines), Self.kindOrder(of: excerpt))
        XCTAssertEqual(lines.first, "Nextflow version: \(NextflowStandInEngine.version)", "the sentinel, not the lock's 26.04.6")
        XCTAssertEqual(lines.first { $0.hasPrefix("[WORKDIR] ") }, "[WORKDIR] \(work.path)")
        XCTAssertEqual(lines.first { $0.hasPrefix("[PIPELINE] ") }, "[PIPELINE] nf-core/taxtriage 1.0dev | profile=\(TaxTriageStandInEngine.profile)")
        XCTAssertEqual(lines.last, "[SUCCESS] completed=46 failed=0 cached=0")

        let rows = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, 46)
        XCTAssertEqual(rows.filter { $0.hasSuffix("\tCOMPLETED\t0") }.count, 46)
        for sample in ["SRR12486983", "SRR12486989"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("report/\(sample).odr.txt").path))
        }
        let recorded = try XCTUnwrap(engine.launches().first)
        XCTAssertEqual(recorded.environment["HOME"], engine.home.path)
        XCTAssertEqual(recorded.environment["NXF_ANSI_LOG"], "false")
    }

    /// The progress-lines mode prints the 2.8 lines byte for byte, which the TaxTriage wrapper
    /// keeps until U10 flips it, and both modes report the 25.04.6 sentinel to `-version`.
    func testProgressLinesKeepThe28LinesAndBothModesKeepTheSentinel() throws {
        let legacy = try NextflowStandInEngine(
            root: root.appendingPathComponent("legacy", isDirectory: true),
            workflow: .taxTriage,
            outputMode: .progressLines25
        )
        let plain = try NextflowStandInEngine(root: root.appendingPathComponent("plain", isDirectory: true), workflow: .taxTriage)
        let sheet = try writeSamplesheet(["S1"])
        let output = root.appendingPathComponent("output", isDirectory: true)
        let result = try ProcessRunner.run(legacy.nextflow, [
            "-c", output.appendingPathComponent("lungfish.nextflow.config").path,
            "run", "jhuapl-bio/taxtriage", "-r", "e10bfebda32a62711f38a4e23ab03b61725a9675", "-profile", TaxTriageStandInEngine.profile,
            "--input", sheet.path, "--outdir", output.path,
        ], timeout: 60)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        N E X T F L O W  ~  version 25.04.6
        Launching jhuapl-bio/taxtriage [stand-in] DSL2
        [aa/000001] Submitted process > NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 (S1)
        [aa/000001] process > NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 (S1) [100%] 1 of 1
        -[nf-core/taxtriage] Pipeline completed successfully-

        """)
        for engine in [legacy, plain] {
            let version = try ProcessRunner.run(engine.nextflow, ["-version"], timeout: 60)
            XCTAssertEqual(version.stdout, "nextflow version \(NextflowStandInEngine.version).5954\n")
        }
        XCTAssertEqual(try plain.launches().count, 0, "-version records no launch")
    }

    // MARK: - Engine options

    /// A launch records the values of `-c`, `-r`, `-profile`, `-w`, `-work-dir` and
    /// `-params-file`, makes the work folder either form names, and prints the remote target's
    /// revision where a snapshot prints `local`.
    func testLaunchRecordsTheEngineOptions() throws {
        let engine = try NextflowStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), workflow: .taxTriage)
        let sheet = try writeSamplesheet(["S1"])
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        let pinned = try ProcessRunner.run(engine.nextflow, [
            "-c", "/configs/a.config", "-c", "/configs/b.config",
            "run", "jhuapl-bio/taxtriage", "-r", "e10bfebda32a", "-profile", "local",
            "-work-dir", first.appendingPathComponent("work").path, "-params-file", "/configs/params.json",
            "--input", sheet.path, "--outdir", first.path,
        ], timeout: 60)
        let plain = try ProcessRunner.run(engine.nextflow, [
            "run", "nf-core/stand-in", "-w", second.appendingPathComponent("work").path,
            "--input", sheet.path, "--outdir", second.path,
        ], timeout: 60)
        XCTAssertEqual([pinned.status, plain.status], [0, 0], pinned.stderr + plain.stderr)

        let launches = try engine.launches()
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches[0].configFiles, ["/configs/a.config", "/configs/b.config"])
        XCTAssertEqual(launches[0].revision, "e10bfebda32a")
        XCTAssertEqual(launches[0].profile, "local")
        XCTAssertEqual(launches[0].workDirectory, first.appendingPathComponent("work").path)
        XCTAssertEqual(launches[0].paramsFile, "/configs/params.json")
        XCTAssertEqual(launches[1].configFiles, [])
        XCTAssertNil(launches[1].revision)
        XCTAssertNil(launches[1].profile)
        XCTAssertEqual(launches[1].workDirectory, second.appendingPathComponent("work").path)
        XCTAssertNil(launches[1].paramsFile)
        for folder in [first, second] {
            let log = folder.appendingPathComponent("work/aa/000001/.command.log")
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "\(log.path) was not made")
        }

        let pinnedLines = pinned.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(pinnedLines.prefix(3)), [
            "Nextflow version: \(NextflowStandInEngine.version)",
            "Commit ID: e10bfebda32a",
            "Repository URL: https://github.com/jhuapl-bio/taxtriage",
        ])
        XCTAssertEqual(pinnedLines[4], "[PIPELINE] nf-core/taxtriage 1.0dev | profile=local")
        XCTAssertEqual(plain.stdout.split(separator: "\n").map(String.init)[4], "[PIPELINE] nf-core/taxtriage 1.0dev | profile=standard")
    }

    // MARK: - Faults in the plain-log mode

    /// A failing sample stops the run at its classifier with Nextflow's task error and nf-core's
    /// failure line, and an ignored task failure leaves the note TaxTriage parses, the warning
    /// line and a `[SUCCESS]` line that counts it. R1 holds neither, so these pin the stand-in.
    func testPlainLogFailsASampleAndReportsAnIgnoredTask() throws {
        let failing = try NextflowStandInEngine(
            root: root.appendingPathComponent("failing", isDirectory: true),
            workflow: .taxTriage,
            behaviour: .failsSamples(["S2"])
        )
        let errored = try NextflowStandInEngine(
            root: root.appendingPathComponent("errored", isDirectory: true),
            workflow: .taxTriage,
            behaviour: .reportsErroredTasks
        )
        let classifier = "NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2"
        let alignment = "NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN"

        let failedOutput = root.appendingPathComponent("failed-output", isDirectory: true)
        let failed = try ProcessRunner.run(failing.nextflow, [
            "run", "jhuapl-bio/taxtriage", "--input", try writeSamplesheet(["S1", "S2"]).path,
            "--outdir", failedOutput.path, "-with-trace", failedOutput.appendingPathComponent("trace.txt").path,
        ], timeout: 60)
        XCTAssertEqual(failed.status, 1)
        XCTAssertEqual(failed.stderr, "ERROR ~ Error executing process > '\(classifier) (S2)'\n")
        let failedLines = failed.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(failedLines.last, "-\u{1B}[0;35m[nf-core/taxtriage]\u{1B}[0;31m Pipeline completed with errors\u{1B}[0m-")
        XCTAssertEqual(failedLines.filter { $0.hasPrefix("[PROCESS ") && $0.hasSuffix(" \(classifier) (S2)") }.count, 1)
        XCTAssertEqual(failedLines.filter { $0.hasPrefix("[SUCCESS]") }, [])
        let failedRows = try String(contentsOf: failedOutput.appendingPathComponent("trace.txt"), encoding: .utf8)
        XCTAssertEqual(failedRows.split(separator: "\n").filter { $0.hasSuffix("\t\(classifier) (S2)\tFAILED\t1") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedOutput.appendingPathComponent("report").path))

        let erroredOutput = root.appendingPathComponent("errored-output", isDirectory: true)
        let ignored = try ProcessRunner.run(errored.nextflow, [
            "run", "jhuapl-bio/taxtriage", "--input", try writeSamplesheet(["S1"]).path,
            "--outdir", erroredOutput.path, "-with-trace", erroredOutput.appendingPathComponent("trace.txt").path,
        ], timeout: 60)
        XCTAssertEqual(ignored.status, 0, ignored.stderr)
        let ignoredLines = ignored.stdout.split(separator: "\n").map(String.init)
        let note = "NOTE: Process `\(alignment) (S1.S1.dwnld.references)` terminated with an error exit status (137) -- Error is ignored"
        XCTAssertEqual(ignoredLines.filter { $0.hasSuffix("] " + note) }.count, 1)
        let completion = try XCTUnwrap(ignoredLines.dropLast().last)
        XCTAssertNotNil(completion.range(of: "completed successfully, but with errored process"), completion)
        XCTAssertEqual(ignoredLines.last, "[SUCCESS] completed=28 failed=1 cached=0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: erroredOutput.appendingPathComponent("report/S1.odr.txt").path))
    }

    // MARK: - Viral Recon (Phase 2.10 lane Q33)

    /// Viral Recon through `engineLaunch`, the direct launch `workflow run` takes, with its options
    /// where `workflow run` puts them today: the parameters sorted by name, then the resource-limit
    /// `-c` and `-work-dir`. The stand-in prints the pinned release's logo, its manifest line and one
    /// task line per task, and writes the files LGE reads back for each sample.
    func testViralReconRunsOnTheDirectLaunchWithTheOptionsWorkflowRunPasses() throws {
        let engine = try NextflowStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), workflow: .viralRecon)
        let sheet = try writeViralReconSamplesheet(["S1", "S2"])
        let output = root.appendingPathComponent("results", isDirectory: true)
        let scratch = root.appendingPathComponent("nfcore-run-1", isDirectory: true)
        let config = scratch.appendingPathComponent("lungfish-resource-limits.config")
        let work = scratch.appendingPathComponent("work", isDirectory: true)
        let result = try launchDirectly(engine.engineLaunch, [
            "run", "nf-core/viralrecon", "-r", "3.0.0", "-profile", "docker",
            "--genome", "MN908947.3", "--input", sheet.path, "--outdir", output.path, "--platform", "illumina",
            "--protocol", "amplicon", "--skip_freyja", "true", "--skip_freyja_boot", "true",
            "-c", config.path, "-work-dir", work.path,
        ])
        XCTAssertEqual(result.status, 0, result.stderr)

        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(8)), Self.viralReconLogo)
        XCTAssertEqual(Array(lines.dropFirst(8).prefix(2)), ["[PIPELINE] nf-core/viralrecon 3.0.0 | profile=docker", "[WORKDIR] \(work.path)"])
        let tasks = lines.filter { $0.hasPrefix("[PROCESS ") }
        XCTAssertEqual(tasks.count, NextflowStandInWorkflow.viralRecon.taskCount(sampleCount: 2))
        XCTAssertEqual(tasks.count, 59, "29 tasks for each sample and MultiQC")
        XCTAssertEqual(tasks.filter { $0.hasSuffix(":FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (S2)") }.count, 1)
        XCTAssertEqual(tasks.last.map(Self.shape), "[PROCESS <hash>] NFCORE_VIRALRECON:VIRALRECON:MULTIQC")
        // Q35's V1 trace: CAT_FASTQ (<sample>) is the first task each sample submits.
        XCTAssertEqual(
            ["S1", "S2"].map { sample in tasks.first { $0.hasSuffix(" (\(sample))") }.map(Self.shape) },
            ["S1", "S2"].map { "[PROCESS <hash>] NFCORE_VIRALRECON:VIRALRECON:CAT_FASTQ (\($0))" }
        )
        // Q35's V1b: the app passes no Nextclade dataset, so the release never starts NEXTCLADE_RUN.
        XCTAssertEqual(tasks.filter { $0.contains(":NEXTCLADE_RUN") }, [])
        XCTAssertEqual(Array(lines.suffix(2)), [
            "-\u{1B}[0;35m[nf-core/viralrecon]\u{1B}[0;32m Pipeline completed successfully\u{1B}[0m-",
            "[SUCCESS] completed=59 failed=0 cached=0",
        ])

        let fixtures = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        for sample in ["S1", "S2"] {
            let copies = [
                ("variants/bowtie2/\(sample).sorted.bam", "test.paired_end.sorted.bam"),
                ("variants/bowtie2/\(sample).ivar_trim.sorted.bam.bai", "test.paired_end.sorted.bam.bai"),
                ("variants/ivar/\(sample).vcf.gz", "test.vcf.gz"),
                ("variants/ivar/\(sample).vcf.gz.tbi", "test.vcf.gz.tbi"),
            ]
            for (written, source) in copies {
                XCTAssertEqual(
                    try Data(contentsOf: output.appendingPathComponent(written)),
                    try Data(contentsOf: fixtures.appendingPathComponent(source)), written)
            }
            let consensus = try String(contentsOf: output.appendingPathComponent("variants/ivar/consensus/bcftools/\(sample).consensus.fa"), encoding: .utf8)
            let reference = try String(contentsOf: fixtures.appendingPathComponent("genome.fasta"), encoding: .utf8)
            XCTAssertEqual(consensus, reference.replacingOccurrences(of: ">", with: ">\(sample) "), "RENAME_FASTA_HEADER's prefix")
        }

        let launch = try XCTUnwrap(engine.launches().first)
        XCTAssertEqual(launch.configFiles, [config.path])
        XCTAssertEqual(launch.workDirectory, work.path)
        XCTAssertEqual(launch.revision, "3.0.0")
        XCTAssertEqual(launch.profile, "docker")
        XCTAssertNil(launch.paramsFile)
        XCTAssertEqual(launch.environment["NXF_ANSI_LOG"], "false")
        XCTAssertEqual(launch.fastqRecords.map(\.column), ["fastq_1", "fastq_2", "fastq_1", "fastq_2"])
        XCTAssertEqual(Set(launch.fastqRecords.map(\.records)).count, 1, "\(launch.fastqRecords)")
        XCTAssertGreaterThan(launch.fastqRecords.first?.records ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("aa/000001/.command.log").path))
    }

    /// A JSON `-params-file` gives the launch its samplesheet and output folder as Nextflow reads
    /// it, the command line's `--outdir` wins over the file's, and a file with no input is refused.
    func testAParamsFileGivesInputAndOutdirAndTheCommandLineWins() throws {
        let engine = try NextflowStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), workflow: .viralRecon)
        let sheet = try writeViralReconSamplesheet(["S1"])
        let fromFile = root.appendingPathComponent("from-file", isDirectory: true)
        let fromCommandLine = root.appendingPathComponent("from-command-line", isDirectory: true)
        let params = root.appendingPathComponent("params.json")
        try JSONSerialization.data(withJSONObject: ["input": sheet.path, "outdir": fromFile.path, "platform": "illumina"])
            .write(to: params)
        let noInput = root.appendingPathComponent("no-input.json")
        try JSONSerialization.data(withJSONObject: ["outdir": fromFile.path]).write(to: noInput)

        let byFile = try ProcessRunner.run(engine.nextflow, ["run", "nf-core/viralrecon", "-params-file", params.path], timeout: 60)
        let overridden = try ProcessRunner.run(engine.nextflow, [
            "run", "nf-core/viralrecon", "-params-file", params.path, "--outdir", fromCommandLine.path,
        ], timeout: 60)
        let refused = try ProcessRunner.run(engine.nextflow, ["run", "nf-core/viralrecon", "-params-file", noInput.path], timeout: 60)

        XCTAssertEqual([byFile.status, overridden.status], [0, 0], byFile.stderr + overridden.stderr)
        XCTAssertEqual(refused.status, 64)
        XCTAssertEqual(refused.stderr, "ERROR ~ The stand-in Nextflow needs a readable --input and an --outdir\n")
        for folder in [fromFile, fromCommandLine] {
            let consensus = folder.appendingPathComponent("variants/ivar/consensus/bcftools/S1.consensus.fa")
            XCTAssertTrue(FileManager.default.fileExists(atPath: consensus.path), consensus.path)
        }
        let launches = try engine.launches()
        XCTAssertEqual(launches.map(\.paramsFile), [params.path, params.path, noInput.path])
        XCTAssertEqual(launches.map { $0.value(after: "--outdir") }, [nil, fromCommandLine.path, nil])
        XCTAssertEqual(launches[0].samplesheet, try Data(contentsOf: sheet))
    }

    /// A sample of `.failsSamples` stops the run at its Bowtie 2 alignment with Nextflow's task
    /// error, and the run writes no sample's outputs.
    func testViralReconFailsASampleAtItsAlignment() throws {
        let engine = try NextflowStandInEngine(
            root: root.appendingPathComponent("engine", isDirectory: true),
            workflow: .viralRecon,
            behaviour: .failsSamples(["S2"])
        )
        let output = root.appendingPathComponent("results", isDirectory: true)
        let result = try ProcessRunner.run(engine.nextflow, [
            "run", "nf-core/viralrecon", "--input", try writeViralReconSamplesheet(["S1", "S2"]).path, "--outdir", output.path,
        ], timeout: 60)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stderr, "ERROR ~ Error executing process > 'NFCORE_VIRALRECON:VIRALRECON:FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (S2)'\n")
        XCTAssertEqual(result.stdout.split(separator: "\n").last.map(String.init), "-\u{1B}[0;35m[nf-core/viralrecon]\u{1B}[0;31m Pipeline completed with errors\u{1B}[0m-")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("variants").path))
    }

    /// The eight lines of `before_text` in subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf
    /// at tag 3.0.0, with the manifest version, after the empty line it starts with.
    private static let viralReconLogo: [String] = {
        let esc = "\u{1B}"
        return [
            "-\(esc)[2m----------------------------------------------------\(esc)[0m-",
            "                                        \(esc)[0;32m,--.\(esc)[0;30m/\(esc)[0;32m,-.\(esc)[0m",
            "\(esc)[0;34m        ___     __   __   __   ___     \(esc)[0;32m/,-._.--~'\(esc)[0m",
            "\(esc)[0;34m  |\\ | |__  __ /  ` /  \\ |__) |__         \(esc)[0;33m}  {\(esc)[0m",
            "\(esc)[0;34m  | \\| |       \\__, \\__/ |  \\ |___     \(esc)[0;32m\\`-._,-`-,\(esc)[0m",
            "                                        \(esc)[0;32m`._,._,'\(esc)[0m",
            "\(esc)[0;35m  nf-core/viralrecon 3.0.0\(esc)[0m",
            "-\(esc)[2m----------------------------------------------------\(esc)[0m-",
        ]
    }()

    /// A Viral Recon Illumina samplesheet that names the nf-core/test-datasets read pair of
    /// Tests/Fixtures/sarscov2 for each sample.
    private func writeViralReconSamplesheet(_ samples: [String]) throws -> URL {
        let reads = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        let folder = root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rows = ["sample,fastq_1,fastq_2"] + samples.map {
            "\($0),\(reads.appendingPathComponent("test_1.fastq.gz").path),\(reads.appendingPathComponent("test_2.fastq.gz").path)"
        }
        let sheet = folder.appendingPathComponent("samplesheet.csv")
        try (rows.joined(separator: "\n") + "\n").write(to: sheet, atomically: true, encoding: .utf8)
        return sheet
    }

    // MARK: - Support files

    /// The pin of `rg -n "@testable" Tests/Support` (ARCH API ruling, risk 2). The stand-in engines
    /// and the classifier fixture reach `CondaManager` through its package initializer.
    func testNoSupportFileImportsAModuleForTesting() throws {
        let support = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Support", isDirectory: true)
        var hits: [String] = []
        for file in try repositoryFiles(under: support) {
            let lines = try readRepositorySource(file).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.range(of: "@testable") != nil {
                hits.append("\(file.lastPathComponent):\(index + 1): \(line)")
            }
        }
        XCTAssertEqual(hits, [])
    }

    // MARK: - Helpers

    /// Runs one launch of `launch` with `arguments` from a launch folder of its own.
    private func launchDirectly(_ launch: WorkflowEngineLaunch, _ arguments: [String]) throws -> ProcessResult {
        let folder = root.appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try ProcessRunner.run(
            launch.executableURL,
            launch.arguments(arguments),
            environment: launch.environment,
            cwd: folder,
            timeout: 60
        )
    }

    /// A samplesheet that names each sample with one FASTQ file of one record.
    private func writeSamplesheet(_ samples: [String]) throws -> URL {
        let folder = root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows = ["sample,fastq_1,fastq_2,platform"]
        for sample in samples {
            let fastq = folder.appendingPathComponent("\(sample).fastq")
            try "@\(sample)-1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
            rows.append("\(sample),\(fastq.path),,ILLUMINA")
        }
        let sheet = folder.appendingPathComponent("samplesheet.csv")
        try (rows.joined(separator: "\n") + "\n").write(to: sheet, atomically: true, encoding: .utf8)
        return sheet
    }

    /// A line with what differs between runs replaced: the task hash, the work folder, the date
    /// and the Nextflow version.
    private static func shape(_ line: String) -> String {
        let rules = [
            (#"^\[PROCESS [0-9a-f]{2}/[0-9a-f]{6}\] "#, "[PROCESS <hash>] "),
            (#"^\[WORKDIR\] .+$"#, "[WORKDIR] <folder>"),
            (#"^Date: .+$"#, "Date: <date>"),
            (#"^Nextflow version: [0-9]+\.[0-9]+\.[0-9]+$"#, "Nextflow version: <version>"),
            (#"^\[SUCCESS\] completed=[0-9]+ failed=[0-9]+ cached=[0-9]+$"#, "[SUCCESS] completed=<n> failed=<n> cached=<n>"),
            (#" \| profile=[^ ]+$"#, " | profile=<profile>"),
        ]
        var shaped = line
        for (pattern, replacement) in rules {
            guard let regex = try? Regex(pattern) else { continue }
            shaped = shaped.replacing(regex, with: replacement)
        }
        return shaped
    }

    /// The kinds of line in the order they first appear: the workflow's banner, `[PIPELINE]`,
    /// `[WORKDIR]`, `[PROCESS]`, nf-core's completion line and `[SUCCESS]`.
    private static func kindOrder(of lines: [String]) -> [String] {
        var kinds: [String] = []
        for line in lines {
            let kind: String
            if line.hasPrefix("[PIPELINE]") || line.hasPrefix("[WORKDIR]") || line.hasPrefix("[SUCCESS]") {
                kind = String(line.prefix { $0 != " " })
            } else if line.hasPrefix("[PROCESS ") {
                kind = "[PROCESS]"
            } else if line.hasPrefix("-\u{1B}[0;35m[") {
                kind = "completion"
            } else {
                kind = "banner"
            }
            if kinds.last != kind { kinds.append(kind) }
        }
        return kinds
    }
}

/// Lines 66 to 74 and 78 to 122 of the standard output of Q15's real run R1 (Phase 2.9 evidence
/// realrun/R1/nextflow-stdout.txt): Nextflow 26.04.6 with `NXF_ANSI_LOG=false` running TaxTriage
/// v3.3.8 from its snapshot on SRR12486983 and SRR12486989. Lines 1 to 65 hold warnings and the
/// pipeline's parameter banner, lines 75 to 77 TaxTriage's sample metadata and line 123 a Graphviz
/// warning, none of which the stand-in prints.
private let r1PlainLogExcerpt = #"""
Nextflow version: 26.04.6
Commit ID: local
Repository URL: local
Date: Mon Oct 12 09:19:02 CDT 2026
[PIPELINE] nf-core/taxtriage 1.0dev | profile=docker
[WORKDIR] /var/folders/bs/ny6ppyh96nl0zh1z_0pvdd8m0000gq/T/taxtriage-run-F914C855-B8D1-4F6A-B270-CD8DCC4049E2/work
[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP
[PROCESS 06/2dcb09] NFCORE_TAXTRIAGE:TAXTRIAGE:INPUT_CHECK:SAMPLESHEET_CHECK (samplesheet.csv)
[PROCESS 70/a0dfc6] NFCORE_TAXTRIAGE:TAXTRIAGE:GET_ASSEMBLIES
[PROCESS 98/c3be91] NFCORE_TAXTRIAGE:TAXTRIAGE:PIGZ_COMPRESS (SRR12486983)
[PROCESS b8/ec401a] NFCORE_TAXTRIAGE:TAXTRIAGE:PIGZ_COMPRESS (SRR12486989)
[PROCESS 83/f30d12] NFCORE_TAXTRIAGE:TAXTRIAGE:COUNT_READS (SRR12486989)
[PROCESS 86/a321a9] NFCORE_TAXTRIAGE:TAXTRIAGE:COUNT_READS (SRR12486983)
[PROCESS 7f/0fd7f3] NFCORE_TAXTRIAGE:TAXTRIAGE:FASTP (SRR12486989)
[PROCESS 49/2b6c78] NFCORE_TAXTRIAGE:TAXTRIAGE:FASTP (SRR12486983)
[PROCESS 72/3e8ad5] NFCORE_TAXTRIAGE:TAXTRIAGE:FASTQC (SRR12486989)
[PROCESS a4/e45532] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2 (SRR12486989)
[PROCESS a9/815204] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2 (SRR12486983)
[PROCESS 88/937e75] NFCORE_TAXTRIAGE:TAXTRIAGE:FASTQC (SRR12486983)
[PROCESS 37/22440d] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:REMOVETAXIDSCLASSIFICATION (SRR12486989)
[PROCESS db/10acfc] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KREPORT_TO_KRONATXT (SRR12486989)
[PROCESS 11/d62980] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KREPORT_TO_KRONATXT (SRR12486983)
[PROCESS a1/9e9ebc] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:REMOVETAXIDSCLASSIFICATION (SRR12486983)
[PROCESS a3/ae3a85] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:TOP_HITS (SRR12486989)
[PROCESS d9/5b7f19] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRONA_KTIMPORTTEXT (combined_krona_kreports)
[PROCESS fb/a36a7e] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:MERGEDSUBSPECIES (MergeTopSpeciesAllSamples)
[PROCESS 77/dea8bd] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:TOP_HITS (SRR12486983)
[PROCESS a1/c51d52] NFCORE_TAXTRIAGE:TAXTRIAGE:REFERENCE_PREP:DOWNLOAD_ASSEMBLY (SRR12486989)
[PROCESS fa/64e947] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:MERGEDKRAKENREPORT (MergeKrakenReportsAllSamples)
[PROCESS b5/47cd8c] NFCORE_TAXTRIAGE:TAXTRIAGE:REFERENCE_PREP:DOWNLOAD_ASSEMBLY (SRR12486983)
[PROCESS 2a/02721e] NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:FILTERKRAKEN
[PROCESS b7/ad49eb] NFCORE_TAXTRIAGE:TAXTRIAGE:REFERENCE_PREP:COMBINE_MAPFILES (SRR12486989)
[PROCESS db/9c293c] NFCORE_TAXTRIAGE:TAXTRIAGE:REFERENCE_PREP:MAP_TAXID_ASSEMBLY (SRR12486989)
[PROCESS 61/cf987b] NFCORE_TAXTRIAGE:TAXTRIAGE:REFERENCE_PREP:COMBINE_MAPFILES (SRR12486983)
[PROCESS e2/67db2c] NFCORE_TAXTRIAGE:TAXTRIAGE:REFERENCE_PREP:MAP_TAXID_ASSEMBLY (SRR12486983)
[PROCESS 80/559baa] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486989.SRR12486989.dwnld.references)
[PROCESS c9/65a10f] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)
[PROCESS 15/6788fc] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:SAMTOOLS_INDEX (SRR12486983)
[PROCESS df/7492be] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:SAMTOOLS_INDEX (SRR12486989)
[PROCESS ef/1925aa] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:SAMTOOLS_HIST_COVERAGE (SRR12486989)
[PROCESS aa/5fa787] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:SAMTOOLS_HIST_COVERAGE (SRR12486983)
[PROCESS ef/7fa68a] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:SAMTOOLS_COVERAGE (SRR12486989)
[PROCESS cc/bb59a3] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:SAMTOOLS_COVERAGE (SRR12486983)
[PROCESS 15/a8e848] NFCORE_TAXTRIAGE:TAXTRIAGE:CUSTOM_DUMPSOFTWAREVERSIONS (1)
[PROCESS 81/ad7008] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:ALIGNMENT_PER_SAMPLE (SRR12486983)
[PROCESS 0e/2b2281] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:ALIGNMENT_PER_SAMPLE (SRR12486989)
[PROCESS 29/fbae01] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:SINGLE_REPORT (SRR12486989)
[PROCESS 7e/407347] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:COMBINE_SAMPLES_JSON (all_samples_combined)
[PROCESS cc/39a464] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:SINGLE_REPORT (SRR12486983)
[PROCESS 0f/0e3868] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:ORGANISM_MERGE_REPORT (all)
[PROCESS 2f/d9ea2f] NFCORE_TAXTRIAGE:TAXTRIAGE:MULTIQC
[PROCESS 49/77b03e] NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:CREATE_COMPARISON_REPORT (comparison_full_report)
-\#u{1B}[0;35m[nf-core/taxtriage]\#u{1B}[0;32m Pipeline completed successfully\#u{1B}[0m-
[SUCCESS] completed=46 failed=0 cached=0
"""#

/// Exit statuses that concurrent launches write, one slot each.
private final class StatusTable: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32]

    init(count: Int) {
        storage = Array(repeating: -2, count: count)
    }

    func set(_ index: Int, _ status: Int32) {
        lock.lock()
        storage[index] = status
        lock.unlock()
    }

    var values: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
