import XCTest
import AppKit
import LungfishCore
@testable import LungfishApp

@MainActor
final class GenotypeHaplotypeTapeViewTests: XCTestCase {
    func testRendersExpectedNumberOfSwatches() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        view.configure(loci: ["MHC-A", "MHC-B"], slots: [
            .init(locus: "MHC-A",
                  h1: .reference(tokenIndex: 2, label: "M2A"),
                  h2: .reference(tokenIndex: 3, label: "M3A")),
            .init(locus: "MHC-B",
                  h1: .reference(tokenIndex: 2, label: "M2B"),
                  h2: .reference(tokenIndex: 3, label: "M3B")),
        ])
        XCTAssertEqual(view.swatchCount, 4)
    }

    func testRecombinantStripedRendersWithoutCrash() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        view.configure(loci: ["MHC-A"], slots: [
            .init(locus: "MHC-A",
                  h1: .reference(tokenIndex: 1, label: "M1A"),
                  h2: .recombinant(tokenIndexA: 2, tokenIndexB: 3, label: "recM2M3DR")),
        ])
        XCTAssertEqual(view.swatchCount, 2)
    }

    func testErrorCellRendersWithoutCrash() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        view.configure(loci: ["MHC-A"], slots: [
            .init(locus: "MHC-A",
                  h1: .error(label: "ERR: TMH"),
                  h2: .empty),
        ])
        XCTAssertEqual(view.swatchCount, 2)
    }

    func testAccessibilityLabelComposition() {
        let view = GenotypeHaplotypeTapeView()
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        view.configure(loci: ["MHC-A"], slots: [
            .init(locus: "MHC-A",
                  h1: .reference(tokenIndex: 1, label: "M1A"),
                  h2: .reference(tokenIndex: 1, label: "M1A")),
        ])
        view.sampleAccessibilityLabel = "H17C119"
        guard let children = view.accessibilityChildren() else {
            return XCTFail("Expected accessibility children")
        }
        XCTAssertEqual(children.count, 2)
        if let first = children.first as? NSAccessibilityElement,
           let label = first.accessibilityLabel() {
            XCTAssertTrue(label.contains("H17C119"))
            XCTAssertTrue(label.contains("MHC-A"))
            XCTAssertTrue(label.contains("H1"))
            XCTAssertTrue(label.contains("M1A"))
        } else {
            XCTFail("Expected NSAccessibilityElement child")
        }
    }
}
