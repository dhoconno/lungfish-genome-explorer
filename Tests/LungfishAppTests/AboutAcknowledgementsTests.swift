import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AboutAcknowledgementsTests: XCTestCase {

    func testCurrentSectionsMatchBundledAndVisiblePackTools() throws {
        let sections = AboutAcknowledgements.currentSections()
        let expectedTitles = ["Bundled Bootstrap", PluginPack.requiredSetupPack.name]
            + PluginPack.activeOptionalPacks.map(\.name)
            + ["Supported nf-core Workflows"]

        XCTAssertEqual(sections.map(\.title), expectedTitles)

        let bundled = try XCTUnwrap(sections.first(where: { $0.title == "Bundled Bootstrap" }))
        XCTAssertEqual(bundled.entries.map(\.id), ["micromamba"])

        let required = try XCTUnwrap(sections.first(where: { $0.title == PluginPack.requiredSetupPack.name }))
        XCTAssertEqual(required.entries.map(\.id), try ManagedToolLock.loadFromBundle().tools.map(\.id))

        for pack in PluginPack.activeOptionalPacks {
            let section = try XCTUnwrap(sections.first(where: { $0.title == pack.name }))
            XCTAssertEqual(
                section.entries.map(\.id),
                pack.toolRequirements.compactMap { requirement in
                    requirement.managedDatabaseID == nil ? requirement.id : nil
                }
            )
        }
    }

    func testCurrentSectionsRenderPinnedMetadataForManagedTools() throws {
        let sections = AboutAcknowledgements.currentSections()

        let required = try XCTUnwrap(sections.first(where: { $0.title == PluginPack.requiredSetupPack.name }))
        let nextflow = try XCTUnwrap(required.entries.first(where: { $0.id == "nextflow" }))
        XCTAssertEqual(nextflow.detail, "25.10.4")
        XCTAssertEqual(nextflow.secondaryDetail, "Apache-2.0")
        XCTAssertEqual(nextflow.sourceURL, "https://github.com/nextflow-io/nextflow")

        let bcftools = try XCTUnwrap(required.entries.first(where: { $0.id == "bcftools" }))
        XCTAssertEqual(bcftools.detail, "1.23.1")
        XCTAssertEqual(bcftools.secondaryDetail, "GPL")
        XCTAssertEqual(bcftools.sourceURL, "https://github.com/samtools/bcftools")

        let assembly = try XCTUnwrap(sections.first(where: { $0.title == "Genome Assembly" }))
        let spades = try XCTUnwrap(assembly.entries.first(where: { $0.id == "spades" }))
        XCTAssertEqual(spades.detail, "4.2.0")
        XCTAssertEqual(spades.secondaryDetail, "GPL-2.0-only")
        XCTAssertEqual(spades.sourceURL, "https://github.com/ablab/spades")

        let hifiasm = try XCTUnwrap(assembly.entries.first(where: { $0.id == "hifiasm" }))
        XCTAssertEqual(hifiasm.detail, "0.25.0")
        XCTAssertEqual(hifiasm.secondaryDetail, "MIT")
        XCTAssertEqual(hifiasm.sourceURL, "https://github.com/chhylp123/hifiasm")

        let metagenomics = try XCTUnwrap(sections.first(where: { $0.title == "Metagenomics" }))
        let kraken2 = try XCTUnwrap(metagenomics.entries.first(where: { $0.id == "kraken2" }))
        XCTAssertEqual(kraken2.detail, "2.17.1")
        XCTAssertEqual(kraken2.secondaryDetail, "GPL-3.0-or-later")
        XCTAssertEqual(kraken2.sourceURL, "https://github.com/DerrickWood/kraken2")

        let esviritu = try XCTUnwrap(metagenomics.entries.first(where: { $0.id == "esviritu" }))
        XCTAssertEqual(esviritu.detail, "1.2.0")
        XCTAssertEqual(esviritu.secondaryDetail, "MIT")
        XCTAssertEqual(esviritu.sourceURL, "https://github.com/cmmr/EsViritu")
    }

    func testCurrentSectionsExcludeInactiveAndRemovedTools() {
        let entryIDs = Set(AboutAcknowledgements.currentSections().flatMap { $0.entries.map(\.id) })

        XCTAssertFalse(entryIDs.contains("metaphlan"))
        XCTAssertFalse(entryIDs.contains("quast"))
        XCTAssertFalse(entryIDs.contains("taxtriage"))
        XCTAssertFalse(entryIDs.contains("nao-mgs"))
    }

    func testCurrentSectionsAcknowledgeCuratedNFCoreWorkflows() throws {
        let sections = AboutAcknowledgements.currentSections()
        let nfCore = try XCTUnwrap(sections.first(where: { $0.title == "Supported nf-core Workflows" }))

        XCTAssertEqual(nfCore.entries.first?.id, "nf-core-fetchngs")
        XCTAssertTrue(nfCore.entries.map(\.id).contains("nf-core-viralrecon"))
        XCTAssertTrue(nfCore.entries.map(\.id).contains("nf-core-vipr"))

        let viralrecon = try XCTUnwrap(nfCore.entries.first(where: { $0.id == "nf-core-viralrecon" }))
        XCTAssertEqual(viralrecon.displayName, "nf-core/viralrecon")
        XCTAssertEqual(viralrecon.detail, "Pinned 3.0.0")
        XCTAssertEqual(viralrecon.secondaryDetail, "Easy Nextflow workflow")
        XCTAssertEqual(viralrecon.sourceURL, "https://nf-co.re/viralrecon")
    }
}
