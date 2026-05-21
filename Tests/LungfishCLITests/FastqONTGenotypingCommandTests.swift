import XCTest
@testable import LungfishCLI

final class FastqONTGenotypingCommandTests: XCTestCase {
    func testFastqCommandRegistersONTGenotype() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("ont-genotype"))
    }

    func testONTGenotypeParsesMultipleInputsAndSimpleOptions() throws {
        let command = try FastqONTGenotypingSubcommand.parse([
            "/tmp/FLD0001.lungfishfastq",
            "/tmp/FLD0002.lungfishfastq",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "mhc-ont-genotyping",
            "--project", "/tmp/project.lungfish",
            "--threads", "8",
            "--min-support", "2",
            "--extra-args", "--tag NM",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/FLD0001.lungfishfastq", "/tmp/FLD0002.lungfishfastq"])
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.outputName, "mhc-ont-genotyping")
        XCTAssertEqual(command.project, "/tmp/project.lungfish")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.minSupport, 2)
        XCTAssertEqual(command.extraArgs, "--tag NM")
    }
}
