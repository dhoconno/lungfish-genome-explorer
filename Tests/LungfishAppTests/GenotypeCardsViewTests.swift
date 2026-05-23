import XCTest
import AppKit
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class GenotypeCardsViewTests: XCTestCase {
    private func makeCard(_ animalId: String, blockKind: GenotypeBlockKind = .blockCoherent) -> GenotypeCardsView.Card {
        GenotypeCardsView.Card(
            animalId: animalId,
            gsId: "DW\(animalId.suffix(3))",
            loci: ["MHC-A", "MHC-B"],
            tapeSlots: [
                .init(locus: "MHC-A",
                      h1: .reference(tokenIndex: 1, label: "M1A"),
                      h2: .reference(tokenIndex: 1, label: "M1A")),
                .init(locus: "MHC-B",
                      h1: .reference(tokenIndex: 1, label: "M1B"),
                      h2: .reference(tokenIndex: 1, label: "M1B")),
            ],
            blockKind: blockKind,
            commentSummary: "M1 homozygous"
        )
    }

    func testRendersOneCardPerSample() {
        let view = GenotypeCardsView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.configure(cards: [
            makeCard("H17C119"),
            makeCard("H18C153", blockKind: .blockCoherent),
            makeCard("H18C126", blockKind: .regionalRecombinant),
        ])
        XCTAssertEqual(view.numberOfCards, 3)
    }

    func testAutoDensityCollapsesToCompactAboveThreshold() {
        let view = GenotypeCardsView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.autoDensityThreshold = 5
        let many = (0..<10).map { makeCard("S\($0)") }
        view.configure(cards: many)
        XCTAssertEqual(view.effectiveDensity, .compact)
    }

    func testAutoDensityStaysComfortableBelowThreshold() {
        let view = GenotypeCardsView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.autoDensityThreshold = 30
        let few = (0..<10).map { makeCard("S\($0)") }
        view.configure(cards: few)
        XCTAssertEqual(view.effectiveDensity, .comfortable)
    }

    func testPinnedDensityOverridesAutoChoice() {
        let view = GenotypeCardsView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.autoDensityThreshold = 5
        view.pinnedDensity = .roomy
        let many = (0..<10).map { makeCard("S\($0)") }
        view.configure(cards: many)
        XCTAssertEqual(view.effectiveDensity, .roomy)
    }
}
