import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class GATKCommandTests: XCTestCase {
    func testHaplotypeCallerDryRunPrintsConstructedCommand() async throws {
        let command = try GATKCLICommand.HaplotypeCallerSubcommand.parse([
            "haplotype-caller",
            "--reference", "/tmp/ref.fa",
            "--bam", "/tmp/sample.bam",
            "--output", "/tmp/sample.g.vcf.gz",
        ])
        let recorder = GATKLineRecorder()

        try await command.executeForTesting { recorder.append($0) }

        let line = try XCTUnwrap(recorder.lines().first)
        XCTAssertTrue(line.contains("gatk HaplotypeCaller"))
        XCTAssertTrue(line.contains("-ERC GVCF"))
        XCTAssertTrue(line.contains("--sample-ploidy 2"))
    }

    func testVariantsToTableDryRunPrintsFieldArguments() async throws {
        let command = try GATKCLICommand.VariantsToTableSubcommand.parse([
            "variants-to-table",
            "--vcf", "/tmp/cohort.vcf.gz",
            "--fields", "CHROM,POS,DP",
            "--output", "/tmp/cohort.tsv",
        ])
        let recorder = GATKLineRecorder()

        try await command.executeForTesting { recorder.append($0) }

        let line = try XCTUnwrap(recorder.lines().first)
        XCTAssertTrue(line.contains("gatk VariantsToTable"))
        XCTAssertTrue(line.contains("-F CHROM"))
        XCTAssertTrue(line.contains("-F DP"))
    }

    func testHaplotypeCallerParsesExplicitExecutionModeWithoutChangingDryRunDefault() throws {
        let dryRun = try GATKCLICommand.HaplotypeCallerSubcommand.parse([
            "haplotype-caller",
            "--reference", "/tmp/ref.fa",
            "--bam", "/tmp/sample.bam",
            "--output", "/tmp/sample.g.vcf.gz",
        ])
        XCTAssertFalse(dryRun.execute)
        XCTAssertTrue(dryRun.isDryRun)

        let execute = try GATKCLICommand.HaplotypeCallerSubcommand.parse([
            "haplotype-caller",
            "--execute",
            "--reference", "/tmp/ref.fa",
            "--bam", "/tmp/sample.bam",
            "--output", "/tmp/sample.g.vcf.gz",
        ])
        XCTAssertTrue(execute.execute)
        XCTAssertFalse(execute.isDryRun)

        let dryRunOverride = try GATKCLICommand.HaplotypeCallerSubcommand.parse([
            "haplotype-caller",
            "--execute",
            "--dry-run",
            "--reference", "/tmp/ref.fa",
            "--bam", "/tmp/sample.bam",
            "--output", "/tmp/sample.g.vcf.gz",
        ])
        XCTAssertTrue(dryRunOverride.execute)
        XCTAssertTrue(dryRunOverride.isDryRun)
    }

    func testHaplotypeCallerExecuteModeRunsInjectedRunnerAndWritesFinalProvenance() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let reference = try write("ref.fa", contents: ">chr1\nACGT\n", in: tempDir)
        let bam = try write("sample.bam", contents: "bam-bytes", in: tempDir)
        let output = tempDir.appendingPathComponent("final/sample.g.vcf.gz")
        let command = try GATKCLICommand.HaplotypeCallerSubcommand.parse([
            "haplotype-caller",
            "--execute",
            "--reference", reference.path,
            "--bam", bam.path,
            "--output", output.path,
        ])
        let runner = CLIGATKRecordingRunner { gatkCommand in
            XCTAssertEqual(gatkCommand.arguments.first, "HaplotypeCaller")
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("gvcf-bytes".utf8).write(to: output)
            return GATKCommandExecutionResult(exitCode: 0, stdout: "ok", stderr: "", wallTime: 0.5)
        }
        let recorder = GATKLineRecorder()

        try await command.executeForTesting(
            emit: { recorder.append($0) },
            runner: runner,
            toolVersion: "4.6.2.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/tmp/conda/envs/gatk-core"),
            packVersion: "test-pack"
        )

        let provenanceURL = output.deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenance = try decodeProvenance(at: provenanceURL)
        XCTAssertEqual(provenance.steps.first?.outputs.first?.path, output.path)
        XCTAssertEqual(provenance.parameters["packID"]?.stringValue, "gatk-core")
        XCTAssertEqual(provenance.parameters["packVersion"]?.stringValue, "test-pack")
        XCTAssertTrue(recorder.lines().contains { $0.contains(provenanceURL.path) })
        let provenanceJSON = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertFalse(provenanceJSON.contains("/staging/"))
    }

    func testVariantsToTableExecuteModeRunsInjectedRunnerAndWritesFinalProvenance() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let input = try write("cohort.vcf.gz", contents: "vcf-bytes", in: tempDir)
        let output = tempDir.appendingPathComponent("final/cohort.tsv")
        let command = try GATKCLICommand.VariantsToTableSubcommand.parse([
            "variants-to-table",
            "--execute",
            "--vcf", input.path,
            "--fields", "CHROM,POS,GT",
            "--output", output.path,
        ])
        let runner = CLIGATKRecordingRunner { gatkCommand in
            XCTAssertEqual(gatkCommand.arguments.first, "VariantsToTable")
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("CHROM\tPOS\tGT\n".utf8).write(to: output)
            return GATKCommandExecutionResult(exitCode: 0, stdout: "ok", stderr: "", wallTime: 0.5)
        }
        let recorder = GATKLineRecorder()

        try await command.executeForTesting(
            emit: { recorder.append($0) },
            runner: runner,
            toolVersion: "4.6.2.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/tmp/conda/envs/gatk-core")
        )

        let provenanceURL = output.deletingLastPathComponent()
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenance = try decodeProvenance(at: provenanceURL)
        XCTAssertEqual(provenance.name, "GATK VariantsToTable")
        XCTAssertEqual(provenance.steps.first?.outputs.first?.path, output.path)
        XCTAssertEqual(provenance.parameters["option.fields"]?.stringValue, #"["CHROM","POS","GT"]"#)
        let provenanceJSON = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertFalse(provenanceJSON.contains("/staging/"))
    }

    func testBQSRDryRunPrintsRecalibratorAndApplyCommandsWithPassthroughArguments() async throws {
        let command = try GATKCLICommand.BQSRSubcommand.parse([
            "bqsr",
            "--reference", "/tmp/ref.fa",
            "--bam", "/tmp/sample.bam",
            "--known-sites", "/tmp/dbsnp.vcf.gz",
            "--recal-table", "/tmp/sample.recal.table",
            "--output", "/tmp/sample.recal.bam",
            "--extra-args", "--disable-sequence-dictionary-validation",
        ])
        let recorder = GATKLineRecorder()

        try await command.executeForTesting { recorder.append($0) }

        let lines = recorder.lines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("gatk BaseRecalibrator"))
        XCTAssertTrue(lines[0].contains("--known-sites /tmp/dbsnp.vcf.gz"))
        XCTAssertTrue(lines[0].contains("--disable-sequence-dictionary-validation"))
        XCTAssertTrue(lines[1].contains("gatk ApplyBQSR"))
        XCTAssertTrue(lines[1].contains("--bqsr-recal-file /tmp/sample.recal.table"))
        XCTAssertTrue(lines[1].contains("--create-output-bam-index true"))
        XCTAssertTrue(lines[1].contains("--disable-sequence-dictionary-validation"))
    }

    func testMarkDuplicatesDryRunPrintsPicardCommandWithPassthroughArguments() async throws {
        let command = try GATKCLICommand.MarkDuplicatesSubcommand.parse([
            "markdup",
            "--bam", "/tmp/lane1.bam",
            "--bam", "/tmp/lane2.bam",
            "--metrics", "/tmp/markdup.metrics.txt",
            "--output", "/tmp/sample.markdup.bam",
            "--remove-duplicates",
            "--extra-args", "--ASSUME_SORT_ORDER coordinate",
        ])
        let recorder = GATKLineRecorder()

        try await command.executeForTesting { recorder.append($0) }

        let line = try XCTUnwrap(recorder.lines().first)
        XCTAssertTrue(line.contains("gatk MarkDuplicates"))
        XCTAssertTrue(line.contains("-I /tmp/lane1.bam"))
        XCTAssertTrue(line.contains("-I /tmp/lane2.bam"))
        XCTAssertTrue(line.contains("-M /tmp/markdup.metrics.txt"))
        XCTAssertTrue(line.contains("--REMOVE_DUPLICATES true"))
        XCTAssertTrue(line.contains("--ASSUME_SORT_ORDER coordinate"))
    }

    func testRemainingWrappedTierDryRunsPrintCommandsWithPassthroughArguments() async throws {
        let validate = try GATKCLICommand.ValidateSamSubcommand.parse([
            "validate-sam",
            "--bam", "/tmp/sample.bam",
            "--output", "/tmp/sample.validation.txt",
            "--reference", "/tmp/ref.fa",
            "--mode", "VERBOSE",
            "--extra-args", "--MAX_OUTPUT 5",
        ])
        let leftalign = try GATKCLICommand.LeftAlignSubcommand.parse([
            "leftalign",
            "--reference", "/tmp/ref.fa",
            "--vcf", "/tmp/cohort.vcf.gz",
            "--output", "/tmp/cohort.left.vcf.gz",
            "--split-multi-allelics",
            "--extra-args", "--dont-trim-alleles",
        ])
        let metrics = try GATKCLICommand.CollectMetricsSubcommand.parse([
            "collect-metrics",
            "--vcf", "/tmp/cohort.vcf.gz",
            "--output-prefix", "/tmp/metrics/cohort",
            "--dbsnp", "/tmp/dbsnp.vcf.gz",
            "--sequence-dictionary", "/tmp/ref.dict",
            "--gvcf-input",
            "--extra-args", "--THREAD_COUNT 2",
        ])
        let recorder = GATKLineRecorder()

        try await validate.executeForTesting { recorder.append($0) }
        try await leftalign.executeForTesting { recorder.append($0) }
        try await metrics.executeForTesting { recorder.append($0) }

        let lines = recorder.lines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("gatk ValidateSamFile"))
        XCTAssertTrue(lines[0].contains("--MODE VERBOSE"))
        XCTAssertTrue(lines[0].contains("--MAX_OUTPUT 5"))
        XCTAssertTrue(lines[1].contains("gatk LeftAlignAndTrimVariants"))
        XCTAssertTrue(lines[1].contains("--split-multi-allelics true"))
        XCTAssertTrue(lines[1].contains("--dont-trim-alleles"))
        XCTAssertTrue(lines[2].contains("gatk CollectVariantCallingMetrics"))
        XCTAssertTrue(lines[2].contains("--GVCF_INPUT true"))
        XCTAssertTrue(lines[2].contains("--THREAD_COUNT 2"))
    }
}

private final class GATKLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor CLIGATKRecordingRunner: GATKCommandRunning {
    typealias Handler = @Sendable (GATKCommand) async throws -> GATKCommandExecutionResult

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        try await handler(command)
    }
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GATKCommandTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ name: String, contents: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func decodeProvenance(at url: URL) throws -> WorkflowRun {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: url))
}
