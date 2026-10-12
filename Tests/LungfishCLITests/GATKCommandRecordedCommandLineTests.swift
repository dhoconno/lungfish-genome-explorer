// GATKCommandRecordedCommandLineTests.swift - an executed gatk run records the lungfish-cli command that ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// Row 163 of Phase 2.4, closed in Phase 2.8. `lungfish-cli gatk <subcommand> --execute` writes its
/// record through `GATKPipelineExecutor`, which built the record from the GATK steps alone, so the
/// record named no `lungfish-cli` command. The app's CLI gate, `GUIImportedProvenanceRehydrator`,
/// refuses a record that names none, which sends a user who attaches the VCF of a CLI run to the
/// import workflow. A stand-in GATK lets the whole command run.
final class GATKCommandRecordedCommandLineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gatk-recorded-command")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAnExecutedRunRecordsTheLungfishCommandAndKeepsTheGATKStep() async throws {
        let run = try makeRun()

        try await execute(run)

        let record = try run.record()
        XCTAssertEqual(record.argv, run.command)
        XCTAssertEqual(record.reproducibleCommand, run.command.map(shellEscape).joined(separator: " "))
        // The command names only files the user chose, so the record needs no replay argv.
        XCTAssertNil(record.durableReplayArgv)
        // The step keeps the GATK command as it ran.
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(Array(step.argv.prefix(2)), ["gatk", "HaplotypeCaller"])
        XCTAssertNil(step.durableReplayArgv)
        XCTAssertEqual(record.status, .completed)
    }

    /// The Attach path of the app (`ProvenanceAwareAttachmentImporter`) rehydrates the record of a CLI
    /// file into the project and refuses a record whose tool and argv name no `lungfish-cli`.
    func testTheRecordPassesTheAppsCLIGate() async throws {
        let run = try makeRun()
        try await execute(run)
        let attached = root.appendingPathComponent("Project/attachments/sample.g.vcf.gz")
        try FileManager.default.createDirectory(
            at: attached.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: run.output, to: attached)

        do {
            _ = try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(from: run.output, to: attached)
        } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance(let path) {
            XCTFail("The CLI gate refused \(path), because its record names no lungfish-cli command.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: attached).path))
    }

    /// A script export replays the steps a record holds, so the GATK command still runs once and the
    /// run's own command does not add a second run of the same analysis.
    func testAShellExportStillReplaysTheGATKStepOnce() async throws {
        let run = try makeRun()
        try await execute(run)

        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            try run.record(),
            format: .shell,
            to: root.appendingPathComponent("export", isDirectory: true),
            sourceSidecarURL: run.recordURL
        )

        let script = try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
        let commands = script.split(separator: "\n").filter { $0.contains("HaplotypeCaller") && !$0.hasPrefix("#") }
        XCTAssertEqual(commands.count, 1, script)
        XCTAssertFalse(script.contains("lungfish-cli gatk"), script)
    }

    /// Inside a project the record holds its paths in the portable form every record there holds, so
    /// the command it names reads in a copy of the project.
    func testARunInsideAProjectRecordsThePortableCommand() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        // A plain VCF, because the executor rewrites the header of a kept bgzipped one with bcftools.
        let run = try makeRun(outputDirectory: try project.folder("Analyses/gatk"), outputName: "sample.vcf")

        try await execute(run)

        let text = try String(contentsOf: run.recordURL, encoding: .utf8)
        XCTAssertFalse(text.contains(project.root.path), "The record holds the project's own path.")
        let record = try run.record()
        XCTAssertEqual(Array(record.argv.prefix(3)), [CLICommandIdentity.executableName, "gatk", "haplotype-caller"])
        XCTAssertTrue(record.argv.contains("@/Analyses/gatk/sample.vcf"), "\(record.argv)")
    }

    func testAFailedRunRecordsTheCommandToo() async throws {
        let run = try makeRun()

        do {
            try await execute(run, exitCode: 3)
            XCTFail("A GATK run that exits 3 must throw.")
        } catch GATKPipelineExecutionError.commandFailed(let exitCode, _) {
            XCTAssertEqual(exitCode, 3)
        }

        let record = try run.record()
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.argv, run.command)
    }

    func testADryRunRunsNothingAndWritesNoRecord() async throws {
        let run = try makeRun()
        let command = try GATKCLICommand.HaplotypeCallerSubcommand.parse(run.arguments + ["--dry-run"])

        try await command.executeForTesting(
            emit: { _ in },
            runner: StandInGATK(output: run.output, exitCode: 0),
            toolVersion: "4.6.2.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/tmp/conda/envs/gatk-core")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: run.output.path), "A dry run ran GATK.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.recordURL.path), "A dry run wrote a record.")
    }

    /// The command line the process was started with names the subcommand, so a run of the shipped
    /// binary records it as typed. Any other argv, such as the test runner's or another subcommand's,
    /// does not.
    func testACommandLineThatNamesTheSubcommandIsRecordedAsTyped() async throws {
        let run = try makeRun()
        let command = try GATKCLICommand.HaplotypeCallerSubcommand.parse(run.arguments)
        let request = try command.executionRequest(toolVersion: "4.6.2.0", runtimeIdentity: GATKRuntimeIdentity())
        let typed = ["/usr/local/bin/lungfish-cli", "gatk"] + run.arguments
        XCTAssertNotEqual(typed, run.command)
        XCTAssertEqual(command.recorded(request, arguments: typed).cliCommandLine, typed)
        let runner = ["/usr/bin/xctest", "-XCTest", "GATKCommandTests", "bundle.xctest"]
        XCTAssertEqual(command.recorded(request, arguments: runner).cliCommandLine, run.command)
        let other = ["/usr/local/bin/lungfish-cli", "gatk", "filter", "--vcf", "in.vcf.gz"]
        XCTAssertEqual(command.recorded(request, arguments: other).cliCommandLine, run.command)

        // The typed command reaches the record as it was typed.
        let result = try await GATKPipelineExecutor(runner: StandInGATK(output: run.output, exitCode: 0))
            .run(command.recorded(request, arguments: typed))
        XCTAssertEqual(try run.record().argv, typed)
        XCTAssertEqual(result.provenanceURL, run.recordURL)
    }

    /// Each subcommand writes the command that runs its options again, and the parser of the shipped
    /// binary reads that command as the same subcommand with the same options.
    func testEverySubcommandSpellsOutItsOptionsAndTheShippedParserTakesThemBack() throws {
        let covered = try [
            assertCanonical(
                GATKCLICommand.HaplotypeCallerSubcommand.self,
                ["--execute", "--reference", "/d/ref.fa", "--bam", "/d/a.bam", "--output", "/d/a.g.vcf.gz",
                 "--intervals", "/d/t.bed", "--ploidy", "1", "--extra-args", "--sample-ploidy 1 --verbosity ERROR"],
                words("""
                    lungfish-cli gatk haplotype-caller --execute --reference /d/ref.fa --bam /d/a.bam
                    --output /d/a.g.vcf.gz --emit-ref-confidence GVCF --ploidy 1 --intervals /d/t.bed
                    --pcr-indel-model CONSERVATIVE --stand-call-conf 30.0 --max-alternate-alleles 6
                    --pair-hmm-threads 4
                    """) + ["--extra-args", "--sample-ploidy 1 --verbosity ERROR"]
            ),
            assertCanonical(
                GATKCLICommand.JointGenotypeSubcommand.self,
                ["--reference", "/d/ref.fa", "--gvcf", "/d/a.g.vcf.gz", "--gvcf", "/d/b.g.vcf.gz",
                 "--output", "/d/cohort.vcf.gz", "--intermediate", "/d/combined.g.vcf.gz",
                 "--combine-strategy", "genomicsdb", "--intervals", "chr1:1-100"],
                words("""
                    lungfish-cli gatk joint-genotype --reference /d/ref.fa --gvcf /d/a.g.vcf.gz
                    --gvcf /d/b.g.vcf.gz --output /d/cohort.vcf.gz --intermediate /d/combined.g.vcf.gz
                    --combine-strategy genomicsdb --intervals chr1:1-100
                    """)
            ),
            assertCanonical(
                GATKCLICommand.FilterSubcommand.self,
                ["--execute", "--vcf", "/d/in.vcf.gz", "--output", "/d/out.vcf.gz"],
                words("""
                    lungfish-cli gatk filter --execute --vcf /d/in.vcf.gz --preset best-practices-both
                    --output /d/out.vcf.gz
                    """)
            ),
            assertCanonical(
                GATKCLICommand.SelectSubcommand.self,
                ["--vcf", "/d/in.vcf.gz", "--sample", "NA12878", "--type", "SNP", "--intervals", "/d/t.bed",
                 "--output", "/d/sel.vcf.gz", "--execute", "--dry-run"],
                words("""
                    lungfish-cli gatk select --execute --dry-run --vcf /d/in.vcf.gz --sample NA12878 --type SNP
                    --intervals /d/t.bed --output /d/sel.vcf.gz
                    """)
            ),
            assertCanonical(
                GATKCLICommand.VariantsToTableSubcommand.self,
                ["--vcf", "/d/cohort.vcf.gz", "--output", "/d/cohort.tsv", "--execute"],
                words("""
                    lungfish-cli gatk variants-to-table --execute --vcf /d/cohort.vcf.gz
                    --fields CHROM,POS,REF,ALT,QUAL,AF,DP --output /d/cohort.tsv
                    """)
            ),
            assertCanonical(
                GATKCLICommand.BQSRSubcommand.self,
                ["--execute", "--reference", "/d/ref.fa", "--bam", "/d/a.bam", "--known-sites", "/d/dbsnp.vcf.gz",
                 "--known-sites", "/d/mills.vcf.gz", "--recal-table", "/d/a.recal", "--output", "/d/a.recal.bam",
                 "--create-output-bam-index", "false"],
                words("""
                    lungfish-cli gatk bqsr --execute --reference /d/ref.fa --bam /d/a.bam
                    --known-sites /d/dbsnp.vcf.gz --known-sites /d/mills.vcf.gz --recal-table /d/a.recal
                    --output /d/a.recal.bam --create-output-bam-index false
                    """)
            ),
            assertCanonical(
                GATKCLICommand.MarkDuplicatesSubcommand.self,
                ["--execute", "--bam", "/d/l1.bam", "--bam", "/d/l2.bam", "--output", "/d/md.bam",
                 "--metrics", "/d/md.txt", "--remove-duplicates", "--validation-stringency", "SILENT",
                 "--extra-args", "--ASSUME_SORT_ORDER coordinate"],
                words("""
                    lungfish-cli gatk markdup --execute --bam /d/l1.bam --bam /d/l2.bam --output /d/md.bam
                    --metrics /d/md.txt --create-index true --remove-duplicates --validation-stringency SILENT
                    """) + ["--extra-args", "--ASSUME_SORT_ORDER coordinate"]
            ),
            assertCanonical(
                GATKCLICommand.ValidateSamSubcommand.self,
                ["--execute", "--bam", "/d/a.bam", "--output", "/d/v.txt", "--reference", "/d/ref.fa",
                 "--mode", "VERBOSE", "--ignore-warnings", "true"],
                words("""
                    lungfish-cli gatk validate-sam --execute --bam /d/a.bam --output /d/v.txt
                    --reference /d/ref.fa --mode VERBOSE --validate-index true --ignore-warnings true
                    """)
            ),
            assertCanonical(
                GATKCLICommand.LeftAlignSubcommand.self,
                ["--execute", "--reference", "/d/ref.fa", "--vcf", "/d/in.vcf.gz", "--output", "/d/left.vcf.gz",
                 "--split-multi-allelics", "--max-indel-length", "100"],
                words("""
                    lungfish-cli gatk leftalign --execute --reference /d/ref.fa --vcf /d/in.vcf.gz
                    --output /d/left.vcf.gz --split-multi-allelics --max-indel-length 100
                    --max-leading-bases 1000
                    """)
            ),
            assertCanonical(
                GATKCLICommand.CollectMetricsSubcommand.self,
                ["--execute", "--vcf", "/d/cohort.vcf.gz", "--output-prefix", "/d/metrics/cohort",
                 "--dbsnp", "/d/dbsnp.vcf.gz", "--sequence-dictionary", "/d/ref.dict", "--gvcf-input"],
                words("""
                    lungfish-cli gatk collect-metrics --execute --vcf /d/cohort.vcf.gz
                    --output-prefix /d/metrics/cohort --dbsnp /d/dbsnp.vcf.gz
                    --sequence-dictionary /d/ref.dict --gvcf-input
                    """)
            ),
        ]

        // A subcommand added to `gatk` fails here until a case above covers it.
        let registered = GATKCLICommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        XCTAssertEqual(covered.sorted(), registered.sorted())
    }

    // MARK: Fixtures

    /// Parses `arguments` as `Command`, checks the command it spells out, and checks that the parser of
    /// the shipped binary takes that command back to the same subcommand with the same command. Returns
    /// the subcommand's name.
    private func assertCanonical<Command: GATKCLIExecutableSubcommand>(
        _ type: Command.Type,
        _ arguments: [String],
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let canonical = try Command.parse(arguments).canonicalArguments()
        XCTAssertEqual(canonical, expected, file: file, line: line)
        let reparsed = try LungfishCLI.parseAsRoot(
            LungfishCLI.normalizedArgumentsForParsing(Array(canonical.dropFirst()))
        )
        let again = try XCTUnwrap(
            reparsed as? Command,
            "The shipped parser read \(canonical) as \(Swift.type(of: reparsed)).",
            file: file,
            line: line
        )
        XCTAssertEqual(again.canonicalArguments(), canonical, file: file, line: line)
        return Command._commandName
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// One `haplotype-caller --execute` run, with the command its record must name.
    private struct Run {
        let reference: URL
        let bam: URL
        let output: URL

        /// The leaf's arguments as a user types them.
        var arguments: [String] {
            ["haplotype-caller", "--execute", "--reference", reference.path, "--bam", bam.path, "--output", output.path]
        }

        /// The command the record names, every option spelled out.
        var command: [String] {
            [
                CLICommandIdentity.executableName, "gatk", "haplotype-caller", "--execute",
                "--reference", reference.path, "--bam", bam.path, "--output", output.path,
                "--emit-ref-confidence", "GVCF", "--ploidy", "2", "--pcr-indel-model", "CONSERVATIVE",
                "--stand-call-conf", "30.0", "--max-alternate-alleles", "6", "--pair-hmm-threads", "4",
            ]
        }

        var recordURL: URL {
            output.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        }

        func record() throws -> ProvenanceEnvelope {
            try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: recordURL))
        }
    }

    /// A run on inputs under the test's folder, whose output goes to `outputDirectory`.
    private func makeRun(outputDirectory: URL? = nil, outputName: String = "sample.g.vcf.gz") throws -> Run {
        let reference = root.appendingPathComponent("ref.fa")
        let bam = root.appendingPathComponent("sample.bam")
        try ">chr1\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        try "bam-bytes".write(to: bam, atomically: true, encoding: .utf8)
        let folder = outputDirectory ?? root.appendingPathComponent("final", isDirectory: true)
        return Run(reference: reference, bam: bam, output: folder.appendingPathComponent(outputName))
    }

    /// Runs the leaf in this process on a stand-in GATK, which throws when `exitCode` is not 0.
    private func execute(_ run: Run, exitCode: Int32 = 0) async throws {
        let command = try GATKCLICommand.HaplotypeCallerSubcommand.parse(run.arguments)
        try await command.executeForTesting(
            emit: { _ in },
            runner: StandInGATK(output: run.output, exitCode: exitCode),
            toolVersion: "4.6.2.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/tmp/conda/envs/gatk-core")
        )
    }
}

/// Stands in for GATK. A run that exits 0 writes the output file, a VCF with a header and no
/// records, and any other exit writes nothing.
private struct StandInGATK: GATKCommandRunning {
    let output: URL
    let exitCode: Int32

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        if exitCode == 0 {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n".utf8).write(to: output)
        }
        return GATKCommandExecutionResult(
            exitCode: exitCode,
            stdout: "",
            stderr: exitCode == 0 ? "" : "stand-in GATK failed",
            wallTime: 0.5
        )
    }
}
