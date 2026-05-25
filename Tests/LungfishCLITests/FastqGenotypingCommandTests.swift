import XCTest
@testable import LungfishCLI

final class FastqGenotypingCommandTests: XCTestCase {
    func testFastqCommandRegistersPlatformNeutralGenotype() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("genotype"))
    }

    func testGenotypeParsesIlluminaPairedInputsWithoutBarcodes() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "--mode", "illumina-paired",
            "--read-type", "illumina",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "miseq-mhc",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-definition", "MHC-exon2-miSeq.rhesus-macaques",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/DW001.lungfishfastq", "/tmp/DW002.lungfishfastq"])
        XCTAssertEqual(command.mode, "illumina-paired")
        XCTAssertEqual(command.readType, "illumina")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "miseq-mhc")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.sortThreads, 2)
        XCTAssertEqual(command.minSupport, 3)
    }
}

