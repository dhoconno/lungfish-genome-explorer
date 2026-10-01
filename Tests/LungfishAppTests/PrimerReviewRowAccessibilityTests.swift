import AppKit
import SwiftUI
import XCTest
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Primer and amplicon marks offer every context-menu command as an
/// accessibility action of the same title, read through the AX bridge.
@MainActor
final class PrimerReviewRowAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private let pasteboard = NSPasteboard.withUniqueName()

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func fixture() -> PrimerTargetDesignReview {
        let primers = [
            PrimerReviewPrimer(id: "left", name: "scheme_1_LEFT_1", start: 5, end: 9, strand: "+", pool: 2,
                nativePool: "2", sequence: "AAGT", ampliconIDs: ["amplicon"]),
            PrimerReviewPrimer(id: "right", name: "scheme_1_RIGHT_1", start: 65, end: 69, strand: "-", pool: 2,
                nativePool: "2", sequence: "CCAT", ampliconIDs: ["amplicon"]),
        ]
        return .init(id: "target", label: "Reference", referenceLength: 100, coverageLabel: "Reference span", coveredBases: 64,
            intervals: [.init(id: "amplicon", start: 5, end: 69, pool: 2, nativePool: "2", name: "scheme_1", primerIDs: primers.map(\.id))],
            primers: primers, notes: [], sourceResultID: "scheme", referenceID: "reference")
    }

    private func host(_ target: PrimerTargetDesignReview, selection: Binding<PrimerReviewSelection?>) -> NSWindow {
        let window = AccessibilityTreeProbe.host(
            PrimerTargetReviewCard(target: target, selection: selection)
                .environment(\.primerReviewActions, PrimerReviewContextActions(targets: [target], onInspectDetails: {}, onExportRequested: { _, _ in }, pasteboard: pasteboard)),
            size: CGSize(width: 700, height: 600)
        )
        windows.append(window)
        return window
    }

    func testPrimerMarkOffersTheContextMenuCommandsAsActions() throws {
        let target = fixture()
        var selected: PrimerReviewSelection?
        let window = host(target, selection: Binding(get: { selected }, set: { selected = $0 }))
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "primerReview.primer.left") != nil
        }
        let mark = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "primerReview.primer.left"),
            "tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        let names = AccessibilityTreeProbe.customActionNames(mark)
        for expected in [
            "Inspect Primer", "Copy Name", "Copy Coordinates", "Copy Sequence (5′–3′)", "Copy as FASTA",
            "Copy Associated Oligos as FASTA", "Copy All Pool 2 Oligos as FASTA",
            "Save Primer FASTA Bundle in Project", "Save Pool 2 Primer FASTA Bundle in Project",
            "Extract Reference Amplicon Bundle in Project",
        ] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing from \(names)")
        }
        XCTAssertFalse(names.contains("Inspect in Alignment"), "a disabled menu command is not an action")
        XCTAssertEqual(names.count, Set(names).count, "each action listed once")
    }

    func testPerformingCopyNameActionCopiesTheClickedPrimerAndSelectsIt() throws {
        let target = fixture()
        var selected: PrimerReviewSelection?
        let window = host(target, selection: Binding(get: { selected }, set: { selected = $0 }))
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "primerReview.primer.right") != nil
        }
        let mark = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: "primerReview.primer.right"))
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Name", on: mark))
        XCTAssertEqual(pasteboard.string(forType: .string), "scheme_1_RIGHT_1")
        XCTAssertEqual(selected?.primerID, "right")
    }

    func testAmpliconMarkOffersInspectAndCopyActions() throws {
        let target = fixture()
        var selected: PrimerReviewSelection?
        let window = host(target, selection: Binding(get: { selected }, set: { selected = $0 }))
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "primerReview.amplicon.amplicon") != nil
        }
        let mark = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: "primerReview.amplicon.amplicon"))
        let names = AccessibilityTreeProbe.customActionNames(mark)
        for expected in ["Inspect Amplicon", "Copy Name", "Copy Coordinates", "Copy Associated Oligos as FASTA"] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing from \(names)")
        }
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Inspect Amplicon", on: mark))
        XCTAssertEqual(selected?.ampliconID, "amplicon")
        XCTAssertNil(selected?.primerID)
    }
}
