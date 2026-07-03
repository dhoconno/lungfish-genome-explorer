import XCTest
import AppKit
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

/// Phase 4 (Task 21): the genotype outline list must virtualize rows so a large
/// cohort does not eagerly build one full view-tree per sample. These tests pin
/// the virtualization contract: a big cohort builds only visible cells, while
/// every sample stays reachable and a small cohort renders exactly as before.
@MainActor
final class GenotypeOutlineVirtualizationTests: XCTestCase {

    /// Hosts the outline view in an off-screen window so the backing
    /// NSTableView/NSScrollView get real clip geometry — without a window the
    /// table never computes a visible-row window and materializes nothing.
    private func host(_ view: GenotypeOutlineView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // GenotypeOutlineView uses autolayout (translatesAutoresizingMaskIntoConstraints
        // = false), so pin it to the content view instead of relying on the
        // autoresizing mask — otherwise it collapses to intrinsic size and the
        // backing table's clip view has zero height.
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
        // Force a draw pass so the backing NSTableView prepares (materializes)
        // the rows in its visible window — headless tests never get an
        // automatic display cycle.
        view.testingForceRowMaterialization()
        return window
    }

    private func makeRow(_ animalId: String) -> GenotypeOutlineView.Row {
        GenotypeOutlineView.Row(
            animalId: animalId,
            gsId: animalId,
            loci: ["MHC-A", "MHC-B"],
            tapeSlots: [
                .init(locus: "MHC-A", h1: .reference(tokenIndex: 1, label: "M1A"), h2: .reference(tokenIndex: 1, label: "M1A")),
                .init(locus: "MHC-B", h1: .reference(tokenIndex: 1, label: "M1B"), h2: .reference(tokenIndex: 1, label: "M1B")),
            ],
            blockKind: .blockCoherent,
            commentSummary: "M1 homozygous",
            noteIssueCount: 0
        )
    }

    /// A 300-sample cohort must NOT instantiate 300 row view-trees up front.
    /// AppKit only materializes cell views for visible rows, so the
    /// construction counter must stay far below the cohort size, while all
    /// 300 rows remain reachable via the row model.
    func testLargeCohortDoesNotEagerlyBuildAllRowViews() {
        let view = GenotypeOutlineView()
        GenotypeOutlineView.testingResetRowViewConstructionCount()
        let rows = (0..<300).map { makeRow("A\($0)") }
        view.configure(rows: rows)
        let window = host(view, size: NSSize(width: 800, height: 600))
        _ = window

        XCTAssertEqual(view.numberOfRows, 300, "all rows remain reachable in the model")

        let built = GenotypeOutlineView.testingRowViewConstructionCount
        XCTAssertGreaterThan(built, 0, "at least the visible rows are built")
        // A ~600pt-tall clip over 34pt rows shows well under ~30 rows even with
        // AppKit's overdraw; the bound proves virtualization, not a per-sample
        // fan-out. Comfortably below the 300-sample cohort.
        XCTAssertLessThan(
            built, 100,
            "virtualization must bound row-view creation to the visible window, not the cohort (built=\(built))"
        )

        // Every sample stays reachable: scrolling to the end materializes the
        // last sample's row without breaking selection wiring.
        view.testingScrollToRow(299)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            view.testingVisibleSampleIds().contains("A299"),
            "scrolling reveals the last sample; it is reachable, not dropped"
        )
    }

    /// A small cohort renders every row (all fit on screen), preserving the
    /// prior behavior where selection + tape rendering are present for all.
    func testSmallCohortRendersAllRowsWithSelectionAndTape() {
        let view = GenotypeOutlineView()
        let rows = (0..<20).map { makeRow("S\($0)") }
        view.configure(rows: rows)
        // Tall enough that all 20 rows fit in the visible window.
        let window = host(view, size: NSSize(width: 800, height: 4_000))
        _ = window

        XCTAssertEqual(view.numberOfRows, 20)

        view.setReviewSelection(sample: "S5", locus: "MHC-B")
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.testingReviewSelectedSample, "S5")
        XCTAssertEqual(view.testingReviewSelectedLocus, "MHC-B")
        XCTAssertEqual(view.testingSelectedTapeLocus(sample: "S5"), "MHC-B")
        XCTAssertNil(view.testingSelectedTapeLocus(sample: "S0"))
        XCTAssertTrue(view.testingHeaderIsSelected(locus: "MHC-B"))

        // Tape swatches are present for every visible sample.
        XCTAssertTrue(view.testingVisibleSampleIds().contains("S0"))
        XCTAssertTrue(view.testingVisibleSampleIds().contains("S19"))
    }

    /// Clicking a row still fires onRowSelected with the sample id, and a tape
    /// cell click still fires onLocusCellClicked with (animalId, locus).
    func testCallbacksPreservedAfterVirtualization() {
        let view = GenotypeOutlineView()
        let rows = (0..<20).map { makeRow("C\($0)") }
        view.configure(rows: rows)
        let window = host(view, size: NSSize(width: 800, height: 600))
        _ = window

        var selected: String?
        var clickedCell: (String, String)?
        view.onRowSelected = { selected = $0 }
        view.onLocusCellClicked = { clickedCell = ($0, $1) }

        view.testingTriggerMaterializedRowClick(sample: "C3")
        XCTAssertEqual(selected, "C3")

        view.testingSimulateTapeClick(sample: "C3", locus: "MHC-B")
        XCTAssertEqual(clickedCell?.0, "C3")
        XCTAssertEqual(clickedCell?.1, "MHC-B")
    }
}
