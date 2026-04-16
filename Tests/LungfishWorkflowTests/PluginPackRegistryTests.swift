import XCTest
@testable import LungfishWorkflow

final class PluginPackRegistryTests: XCTestCase {

    func testRequiredSetupPackIsLungfishTools() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(pack.id, "lungfish-tools")
        XCTAssertEqual(pack.name, "Lungfish Tools")
        XCTAssertTrue(pack.isRequiredBeforeLaunch)
        XCTAssertTrue(pack.isActive)
        XCTAssertEqual(pack.packages, ["nextflow", "snakemake", "bbtools", "fastp"])
    }

    func testRequiredSetupPackDefinesPerToolChecks() {
        let pack = PluginPack.requiredSetupPack
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["nextflow", "snakemake", "bbtools", "fastp"])
        XCTAssertEqual(pack.toolRequirements[2].installPackages, ["bbmap"])
        XCTAssertEqual(pack.toolRequirements[2].executables, [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "java",
        ])
        XCTAssertEqual(pack.toolRequirements[3].executables, ["fastp"])
    }

    func testActiveOptionalPacksOnlyExposeMetagenomics() {
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["metagenomics"])
    }

    func testVisibleCLIPacksIncludeRequiredAndActiveOptional() {
        XCTAssertEqual(PluginPack.visibleForCLI.map(\.id), ["lungfish-tools", "metagenomics"])
    }
}
