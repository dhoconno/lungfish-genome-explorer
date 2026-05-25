import XCTest
@testable import LungfishCLI

final class HaplotypeDefinitionsCommandTests: XCTestCase {
    func testTopLevelCLIRegistersHaplotypeDefinitionManager() {
        let names = LungfishCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("haplotypes"))
    }

    func testImportCommandParsesScopeAndProjectOptions() throws {
        let command = try HaplotypeDefinitionsImportSubcommand.parse([
            "/tmp/mcm.lungfishhaplotypedef.json",
            "--scope", "project",
            "--project", "/tmp/project.lungfish",
            "--change-note", "initial import",
        ])

        XCTAssertEqual(command.input, "/tmp/mcm.lungfishhaplotypedef.json")
        XCTAssertEqual(command.scope, "project")
        XCTAssertEqual(command.project, "/tmp/project.lungfish")
        XCTAssertEqual(command.changeNote, "initial import")
    }

    func testListCommandParsesAllScopeAndCompatibilityFilters() throws {
        let command = try HaplotypeDefinitionsListSubcommand.parse([
            "--scope", "all",
            "--assay", "MHC-exon2-miSeq",
            "--species", "MCM",
            "--include-shadowed",
        ])

        XCTAssertEqual(command.scope, "all")
        XCTAssertEqual(command.assay, "MHC-exon2-miSeq")
        XCTAssertEqual(command.species, "MCM")
        XCTAssertTrue(command.includeShadowed)
    }

    func testValidateCommandParsesInputPath() throws {
        let command = try HaplotypeDefinitionsValidateSubcommand.parse([
            "/tmp/mcm.lungfishhaplotypedef.json",
        ])

        XCTAssertEqual(command.input, "/tmp/mcm.lungfishhaplotypedef.json")
    }

    func testSaveCommandParsesEditableDefinitionOptions() throws {
        let command = try HaplotypeDefinitionsSaveSubcommand.parse([
            "/tmp/mcm-edited.lungfishhaplotypedef.json",
            "--scope", "global",
            "--change-note", "added B haplotype",
        ])

        XCTAssertEqual(command.input, "/tmp/mcm-edited.lungfishhaplotypedef.json")
        XCTAssertEqual(command.scope, "global")
        XCTAssertEqual(command.changeNote, "added B haplotype")
    }

    func testONTBarcodeGenotypingParsesHaplotypeSelectionInputs() throws {
        let command = try FastqONTBarcodeGenotypingSubcommand.parse([
            "/tmp/barcode08.lungfishfastq",
            "--reference", "/tmp/mhc.lungfishref",
            "--barcodes", "/tmp/fluidigm.csv",
            "--output-dir", "/tmp/out",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-species", "MCM",
            "--haplotype-definition-scope", "project",
            "--haplotype-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
        ])

        XCTAssertEqual(command.haplotypeAssay, "MHC-exon2-miSeq")
        XCTAssertEqual(command.haplotypeSpecies, "MCM")
        XCTAssertEqual(command.haplotypeDefinitionScope, "project")
        XCTAssertEqual(command.haplotypeDefinition, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
    }
}
