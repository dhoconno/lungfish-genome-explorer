import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AboutAcknowledgementsTests: XCTestCase {

    func testCurrentSectionsMatchBundledAndVisiblePackTools() throws {
        let sections = AboutAcknowledgements.currentSections()

        XCTAssertEqual(sections.map(\.title), ["Bundled Bootstrap", "Third-Party Tools", "Metagenomics"])

        let bundled = try XCTUnwrap(sections.first(where: { $0.title == "Bundled Bootstrap" }))
        XCTAssertEqual(bundled.entries.map(\.id), ["micromamba"])

        let required = try XCTUnwrap(sections.first(where: { $0.title == PluginPack.requiredSetupPack.name }))
        XCTAssertEqual(required.entries.map(\.id), try ManagedToolLock.loadFromBundle().tools.map(\.id))

        let metagenomics = try XCTUnwrap(sections.first(where: { $0.title == "Metagenomics" }))
        XCTAssertEqual(metagenomics.entries.map(\.id), ["kraken2", "bracken", "esviritu"])
    }

    func testCurrentSectionsExcludeInactiveAndRemovedTools() {
        let entryIDs = Set(AboutAcknowledgements.currentSections().flatMap { $0.entries.map(\.id) })

        XCTAssertFalse(entryIDs.contains("metaphlan"))
        XCTAssertFalse(entryIDs.contains("bwa-mem2"))
        XCTAssertFalse(entryIDs.contains("spades"))
        XCTAssertFalse(entryIDs.contains("taxtriage"))
        XCTAssertFalse(entryIDs.contains("nao-mgs"))
    }
}
