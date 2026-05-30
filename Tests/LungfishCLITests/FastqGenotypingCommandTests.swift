import XCTest
@testable import LungfishCLI

final class FastqGenotypingCommandTests: XCTestCase {
    func testFastqCommandRegistersPlatformNeutralGenotype() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("genotype"))
        XCTAssertTrue(names.contains("mhc-reference-bundle"))
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

    func testMHCReferenceBundleParsesOptions() throws {
        let command = try FastqMHCReferenceBundleSubcommand.parse([
            "--reference-fasta", "/tmp/MCM_MHC.fa",
            "--haplotype-definition", "/tmp/mcm.json",
            "--haplotype-definition", "/tmp/mamu.json",
            "--default-haplotype-definition", "mcm-mhc",
            "--output", "/tmp/MCM-MHC.lungfishmhcref",
            "--name", "MCM MHC",
            "--source-file", "/tmp/build.log",
            "--force",
        ])

        XCTAssertEqual(command.referenceFASTA, "/tmp/MCM_MHC.fa")
        XCTAssertEqual(command.haplotypeDefinitions, ["/tmp/mcm.json", "/tmp/mamu.json"])
        XCTAssertEqual(command.defaultHaplotypeDefinition, "mcm-mhc")
        XCTAssertEqual(command.output, "/tmp/MCM-MHC.lungfishmhcref")
        XCTAssertEqual(command.name, "MCM MHC")
        XCTAssertEqual(command.sourceFiles, ["/tmp/build.log"])
        XCTAssertTrue(command.force)
        XCTAssertEqual(command.configurationForTesting().defaultHaplotypeDefinitionID, "mcm-mhc")
    }
}
