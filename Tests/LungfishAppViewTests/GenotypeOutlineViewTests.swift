import XCTest
import AppKit
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeOutlineViewTests: XCTestCase {
    /// Hosts the outline view in an off-screen window so the backing
    /// (now virtualized) NSTableView materializes its visible rows. Since the
    /// list virtualizes, per-row tape views only exist once the table has real
    /// clip geometry — tree-walking assertions must therefore host first.
    private func host(_ view: GenotypeOutlineView, size: NSSize = NSSize(width: 800, height: 4_000)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let content = window.contentView!
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.testingForceRowMaterialization()
        return window
    }

    func testRendersOneRowPerSample() {
        let view = GenotypeOutlineView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.configure(rows: [
            .init(animalId: "H17C119", gsId: "DW472", loci: ["MHC-A", "MHC-B"], tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 1, label: "M1A"), h2: .reference(tokenIndex: 1, label: "M1A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 1, label: "M1B"), h2: .reference(tokenIndex: 1, label: "M1B")),
            ], blockKind: .blockCoherent, commentSummary: "M1 homozygous", noteIssueCount: 0),
            .init(animalId: "H18C153", gsId: "DW473", loci: ["MHC-A", "MHC-B"], tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 2, label: "M2A"), h2: .reference(tokenIndex: 3, label: "M3A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 2, label: "M2B"), h2: .reference(tokenIndex: 3, label: "M3B")),
            ], blockKind: .blockCoherent, commentSummary: "block M2 / M3", noteIssueCount: 2),
        ])
        XCTAssertEqual(view.numberOfRows, 2)
    }

    func testReviewSelectionMarksSelectedSampleAndLocus() {
        let view = GenotypeOutlineView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.configure(rows: [
            .init(animalId: "H17C119", gsId: "DW472", loci: ["MHC-A", "MHC-B"], tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 1, label: "M1A"), h2: .reference(tokenIndex: 1, label: "M1A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 1, label: "M1B"), h2: .reference(tokenIndex: 1, label: "M1B")),
            ], blockKind: .blockCoherent, commentSummary: "M1 homozygous", noteIssueCount: 0),
            .init(animalId: "H18C153", gsId: "DW473", loci: ["MHC-A", "MHC-B"], tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 2, label: "M2A"), h2: .reference(tokenIndex: 3, label: "M3A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 2, label: "M2B"), h2: .reference(tokenIndex: 3, label: "M3B")),
            ], blockKind: .blockCoherent, commentSummary: "block M2 / M3", noteIssueCount: 2),
        ])

        let window = host(view)
        view.setReviewSelection(sample: "H18C153", locus: "MHC-B")
        window.layoutIfNeeded()
        view.testingForceRowMaterialization()

        XCTAssertEqual(view.testingReviewSelectedSample, "H18C153")
        XCTAssertEqual(view.testingReviewSelectedLocus, "MHC-B")
        XCTAssertEqual(view.testingSelectedTapeLocus(sample: "H18C153"), "MHC-B")
        XCTAssertNil(view.testingSelectedTapeLocus(sample: "H17C119"))
        XCTAssertTrue(view.testingHeaderIsSelected(locus: "MHC-B"))
        XCTAssertFalse(view.testingHeaderIsSelected(locus: "MHC-A"))
    }
}
