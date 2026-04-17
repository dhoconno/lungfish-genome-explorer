import XCTest
@testable import LungfishWorkflow

final class PluginPackRegistryTests: XCTestCase {

    func testRequiredSetupPackIsLungfishTools() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(pack.id, "lungfish-tools")
        XCTAssertEqual(pack.name, "Lungfish Tools")
        XCTAssertTrue(pack.isRequiredBeforeLaunch)
        XCTAssertTrue(pack.isActive)
        XCTAssertEqual(pack.packages, ["nextflow", "snakemake", "bbtools", "fastp", "deacon"])
    }

    func testRequiredSetupPackDefinesPerToolChecks() {
        let pack = PluginPack.requiredSetupPack
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["nextflow", "snakemake", "bbtools", "fastp", "deacon", "deacon-panhuman"])
        XCTAssertEqual(pack.estimatedSizeMB, 1920)
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.installPackages, ["bbmap"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.executables, [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "java",
        ])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "fastp" })?.executables, ["fastp"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon" })?.executables, ["deacon"])
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "deacon-panhuman" })?.displayName,
            "Human Read Removal Data"
        )
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "deacon-panhuman" })?.executables, [])
    }

    func testMetagenomicsPackDefinesSmokeChecksForVisibleTools() {
        let pack = try! XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["kraken2", "bracken", "metaphlan", "esviritu"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "metaphlan" })?.executables, ["metaphlan"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "esviritu" })?.executables, ["esviritu"])
    }

    func testActiveOptionalPacksOnlyExposeMetagenomics() {
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["metagenomics"])
    }

    func testVisibleCLIPacksIncludeRequiredAndActiveOptional() {
        XCTAssertEqual(PluginPack.visibleForCLI.map(\.id), ["lungfish-tools", "metagenomics"])
    }
}
