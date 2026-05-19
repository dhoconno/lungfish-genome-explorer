import XCTest
@testable import LungfishCLI

final class FastqPBAAClusterCommandTests: XCTestCase {
    func testFastqCommandRegistersPBAACluster() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("pbaa-cluster"))
    }

    func testPBAAClusterParsesSimpleGuiOptionsAndAdvancedOptions() throws {
        let command = try FastqPBAAClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--guide", "/tmp/guide.fasta",
            "--output-dir", "/tmp/out",
            "--output-name", "sample",
            "--threads", "4",
            "--seed", "7",
            "--extra-args", "--min-cluster-read-count 2",
        ])

        XCTAssertEqual(command.input, "/tmp/reads.fastq")
        XCTAssertEqual(command.guide, "/tmp/guide.fasta")
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.outputName, "sample")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.seed, 7)
        XCTAssertEqual(command.extraArgs, "--min-cluster-read-count 2")
    }
}
