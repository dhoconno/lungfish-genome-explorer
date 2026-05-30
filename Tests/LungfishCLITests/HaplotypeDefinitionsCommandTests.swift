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
            "--include-reference-bundles",
        ])

        XCTAssertEqual(command.scope, "all")
        XCTAssertEqual(command.assay, "MHC-exon2-miSeq")
        XCTAssertEqual(command.species, "MCM")
        XCTAssertTrue(command.includeShadowed)
        XCTAssertTrue(command.includeReferenceBundles)
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

    func testBundleSaveCommandParsesReferenceBundleOptions() throws {
        let command = try HaplotypeDefinitionsBundleSaveSubcommand.parse([
            "/tmp/mcm-edited.lungfishhaplotypedef.json",
            "--bundle", "/tmp/MCM-MHC.lungfishmhcref",
            "--change-note", "added bundle haplotype",
        ])

        XCTAssertEqual(command.input, "/tmp/mcm-edited.lungfishhaplotypedef.json")
        XCTAssertEqual(command.bundle, "/tmp/MCM-MHC.lungfishmhcref")
        XCTAssertEqual(command.changeNote, "added bundle haplotype")
    }

    func testBundleReplaceReferenceCommandParsesReferenceBundleOptions() throws {
        let command = try HaplotypeDefinitionsBundleReplaceReferenceSubcommand.parse([
            "/tmp/MCM_MHC.fa",
            "--bundle", "/tmp/MCM-MHC.lungfishmhcref",
        ])

        XCTAssertEqual(command.referenceFASTA, "/tmp/MCM_MHC.fa")
        XCTAssertEqual(command.bundle, "/tmp/MCM-MHC.lungfishmhcref")
    }

    func testBundleCreateCommandParsesDefinitionAndReferenceOptions() throws {
        let command = try HaplotypeDefinitionsBundleCreateSubcommand.parse([
            "--definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            "--assay", "MHC-exon2-miSeq",
            "--species", "MCM",
            "--scope", "built-in",
            "--reference-fasta", "/tmp/MCM_MHC.fa",
            "--output", "/tmp/MCM-MHC.lungfishmhcref",
            "--name", "MCM Explicit MHC",
            "--default-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            "--force",
        ])

        XCTAssertEqual(command.definitions, ["MHC-exon2-miSeq.mauritian-cynomolgus-macaques"])
        XCTAssertEqual(command.assay, "MHC-exon2-miSeq")
        XCTAssertEqual(command.species, "MCM")
        XCTAssertEqual(command.scope, "built-in")
        XCTAssertEqual(command.referenceFASTA, "/tmp/MCM_MHC.fa")
        XCTAssertEqual(command.output, "/tmp/MCM-MHC.lungfishmhcref")
        XCTAssertEqual(command.name, "MCM Explicit MHC")
        XCTAssertEqual(command.defaultDefinition, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
        XCTAssertTrue(command.force)
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
