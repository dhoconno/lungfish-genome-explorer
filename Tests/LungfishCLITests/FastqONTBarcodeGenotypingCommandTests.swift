import XCTest
@testable import LungfishCLI

final class FastqONTBarcodeGenotypingCommandTests: XCTestCase {
    func testFastqCommandRegistersONTBarcodeGenotype() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("ont-barcode-genotype"))
    }

    func testONTBarcodeGenotypeParsesExcelReportOptions() throws {
        let command = try FastqONTBarcodeGenotypingSubcommand.parse([
            "/tmp/barcode08.lungfishfastq",
            "--reference", "/tmp/mhc.lungfishref",
            "--barcodes", "/tmp/fluidigm.csv",
            "--demux-manifest", "/tmp/demux-manifest.json",
            "--output-dir", "/tmp/out",
            "--output-name", "barcode08-mhc",
            "--project", "/tmp/project.lungfish",
            "--analysis-name", "ONT08",
            "--comparison-workbook", "/tmp/pbaa.xlsx",
            "--comparison-name", "Illumina-31262",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-definition-scope", "project",
            "--haplotype-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
            "--extra-args", "-N 50",
        ])

        XCTAssertEqual(command.input, "/tmp/barcode08.lungfishfastq")
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.barcodes, "/tmp/fluidigm.csv")
        XCTAssertEqual(command.demuxManifest, "/tmp/demux-manifest.json")
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.outputName, "barcode08-mhc")
        XCTAssertEqual(command.project, "/tmp/project.lungfish")
        XCTAssertEqual(command.analysisName, "ONT08")
        XCTAssertEqual(command.comparisonWorkbook, "/tmp/pbaa.xlsx")
        XCTAssertEqual(command.comparisonName, "Illumina-31262")
        XCTAssertEqual(command.haplotypeAssay, "MHC-exon2-miSeq")
        XCTAssertEqual(command.haplotypeDefinitionScope, "project")
        XCTAssertEqual(command.haplotypeDefinition, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.sortThreads, 2)
        XCTAssertEqual(command.minSupport, 3)
        XCTAssertEqual(command.extraArgs, "-N 50")
    }

    func testONTBarcodeGenotypeStillParsesLegacyDefinitionWithoutAssay() throws {
        let command = try FastqONTBarcodeGenotypingSubcommand.parse([
            "/tmp/barcode08.lungfishfastq",
            "--reference", "/tmp/mhc.lungfishref",
            "--barcodes", "/tmp/fluidigm.csv",
            "--output-dir", "/tmp/out",
            "--haplotype-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
        ])

        XCTAssertNil(command.haplotypeAssay)
        XCTAssertEqual(command.haplotypeDefinition, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
    }
}
