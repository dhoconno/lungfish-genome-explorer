import XCTest
@testable import LungfishCLI

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
