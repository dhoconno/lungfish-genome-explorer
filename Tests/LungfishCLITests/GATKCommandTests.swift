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
