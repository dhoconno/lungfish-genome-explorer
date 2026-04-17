import XCTest
@testable import LungfishWorkflow

final class PluginPackRegistryTests: XCTestCase {

    func testRequiredSetupPackIsLungfishTools() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(pack.id, "lungfish-tools")
        XCTAssertEqual(pack.name, "Third-Party Tools")
        XCTAssertTrue(pack.isRequiredBeforeLaunch)
        XCTAssertTrue(pack.isActive)
        XCTAssertEqual(
            pack.packages,
            [
                "nextflow", "snakemake", "bbtools", "fastp", "deacon",
                "samtools", "bcftools", "htslib", "seqkit", "cutadapt",
                "vsearch", "pigz", "sra-tools", "ucsc-bedtobigbed", "ucsc-bedgraphtobigwig",
            ]
        )
    }

    func testRequiredSetupPackDefinesPerToolChecks() {
        let pack = PluginPack.requiredSetupPack
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, [
            "nextflow", "snakemake", "bbtools", "fastp", "deacon",
            "samtools", "bcftools", "htslib", "seqkit", "cutadapt",
            "vsearch", "pigz", "sra-tools", "ucsc-bedtobigbed", "ucsc-bedgraphtobigwig",
            "deacon-panhuman",
        ])
        XCTAssertEqual(pack.estimatedSizeMB, 2600)
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "bbtools" })?.installPackages,
            ["bioconda::bbmap=39.80=h2e3bd82_0"]
        )
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

    func testRequiredSetupPackMatchesPinnedManagedToolLock() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(lock.packID, "lungfish-tools")
        XCTAssertEqual(lock.displayName, "Third-Party Tools")
        XCTAssertEqual(pack.name, lock.displayName)
        XCTAssertEqual(pack.packages, lock.tools.map(\.environment))
        XCTAssertEqual(lock.tools.count, 15)
        XCTAssertEqual(lock.managedData.count, 1)
    }

    func testMetagenomicsPackDefinesSmokeChecksForVisibleTools() {
        let pack = try! XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "metagenomics" }))
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["kraken2", "bracken", "metaphlan", "esviritu"])
        XCTAssertTrue(pack.toolRequirements.allSatisfy { $0.smokeTest != nil })
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "metaphlan" })?.executables, ["metaphlan"])
        XCTAssertEqual(pack.toolRequirements.first(where: { $0.environment == "esviritu" })?.executables, ["esviritu"])
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "metaphlan" })?.smokeTest?.arguments,
            ["--help"]
        )
    }

    func testRequiredSetupPackUsesLighterSnakemakeSmokeProbe() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "snakemake" })?.smokeTest?.arguments,
            ["--help"]
        )
    }

    func testRequiredSetupPackUsesUsageSmokeProbeForUcscTools() {
        let pack = PluginPack.requiredSetupPack

        for environment in ["ucsc-bedtobigbed", "ucsc-bedgraphtobigwig"] {
            let smokeTest = pack.toolRequirements.first(where: { $0.environment == environment })?.smokeTest
            XCTAssertEqual(smokeTest?.arguments, [])
            XCTAssertEqual(smokeTest?.acceptedExitCodes, [255])
            XCTAssertEqual(smokeTest?.requiredOutputSubstring, "usage:")
        }
    }

    func testActiveOptionalPacksOnlyExposeMetagenomics() {
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["metagenomics"])
    }

    func testVisibleCLIPacksIncludeRequiredAndActiveOptional() {
        XCTAssertEqual(PluginPack.visibleForCLI.map(\.id), ["lungfish-tools", "metagenomics"])
    }
}
