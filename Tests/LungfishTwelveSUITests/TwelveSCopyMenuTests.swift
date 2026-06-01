import XCTest
import AppKit
import LungfishIO
import LungfishKit
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSCopyMenuTests: XCTestCase {

    private func target(_ name: String, taxid: String, reads: Int) -> TwelveSScientificNameCountRow {
        TwelveSScientificNameCountRow(scientificName: name, targetIDs: ["t"],
            sampleCounts: ["s1": reads], sampleExactReadTotals: ["s1": 100], taxids: [taxid])
    }
    private func unresolved(_ id: String, seq: String) -> TwelveSUnresolvedSequence {
        TwelveSUnresolvedSequence(sequenceID: id, sequence: seq, readCount: 1,
            sampleCounts: ["s1": 1], chimeraStatus: .notReviewed)
    }

    func testCopyNameSingleAndMulti() {
        XCTAssertEqual(TwelveSCopyFormatting.names([target("Homo sapiens", taxid: "9606", reads: 1)]), "Homo sapiens")
        let two = [target("Homo sapiens", taxid: "9606", reads: 1), target("Gallus gallus", taxid: "9031", reads: 1)]
        XCTAssertEqual(TwelveSCopyFormatting.names(two), "Homo sapiens\nGallus gallus")
    }

    func testCopySequenceAndFASTA() {
        XCTAssertEqual(TwelveSCopyFormatting.sequence(unresolved("c1", seq: "ACGT")), "ACGT")
        let fasta = TwelveSCopyFormatting.fasta([unresolved("c1", seq: "ACGT"), unresolved("c2", seq: "TTTT")])
        XCTAssertEqual(fasta, ">c1\nACGT\n>c2\nTTTT")
    }

    func testCopyTargetRowsTSVHasHeaderAndValues() {
        let tsv = TwelveSCopyFormatting.targetRowsTSV([target("Homo sapiens", taxid: "9606", reads: 42)])
        let lines = tsv.split(separator: "\n")
        XCTAssertEqual(lines.first, "Scientific Name\tCommon Names\tGroup\tTax ID\tExact Reads\tRefs\tMax %\tAlternates")
        XCTAssertTrue(lines[1].contains("Homo sapiens"))
        XCTAssertTrue(lines[1].contains("42"))
    }

    func testCopyUnresolvedRowsTSVHasHeaderAndValues() {
        let tsv = TwelveSCopyFormatting.unresolvedRowsTSV([unresolved("c1", seq: "ACGT")])
        let lines = tsv.split(separator: "\n")
        XCTAssertEqual(lines.first, "Sequence\tReads\tSamples\tChimera\tBases")
        XCTAssertTrue(lines[1].contains("c1"))
        XCTAssertTrue(lines[1].contains("ACGT"))
    }

    private final class SpyPasteboard: PasteboardWriting {
        var last: String?
        func setString(_ s: String) { last = s }
    }

    func testTargetMenuPopulatesAndCopyNameWritesPasteboard() {
        let spy = SpyPasteboard()
        let menu = NSMenu()
        let rows = [target("Homo sapiens", taxid: "9606", reads: 5)]
        TwelveSCopyMenuProvider.populateTargetMenu(menu, rows: rows, pasteboard: spy)
        XCTAssertEqual(menu.items.map(\.title), ["Copy Name"])
        // fire the single item through NSMenu's action machinery
        menu.performActionForItem(at: 0)
        XCTAssertEqual(spy.last, "Homo sapiens")
    }

    func testUnresolvedMultiMenuCopySequencesWritesFASTA() {
        let spy = SpyPasteboard()
        let menu = NSMenu()
        let rows = [unresolved("c1", seq: "ACGT"), unresolved("c2", seq: "TTTT")]
        TwelveSCopyMenuProvider.populateUnresolvedMenu(menu, rows: rows, pasteboard: spy)
        XCTAssertEqual(menu.items.map(\.title), ["Copy Names", "Copy Sequences", "Copy Rows"])
        menu.performActionForItem(at: 1) // Copy Sequences
        XCTAssertEqual(spy.last, ">c1\nACGT\n>c2\nTTTT")
    }

    func testViewControllerCopyNameWritesPasteboard() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let spy = SpyPasteboard()
        vc.testingSetPasteboard(spy)
        vc.configure(result: TwelveSFixtures.twoSampleResult())
        vc.testingCopyNameForSelectedRow(0)
        XCTAssertNotNil(spy.last)
        XCTAssertFalse(spy.last!.isEmpty)
    }

    func testMenuItemsGatedBySelectionAndMode() {
        // single unresolved → Copy Name + Copy Sequence; no Copy Sequences / Copy Rows
        let single = TwelveSCopyMenuProvider.itemTitles(mode: .unresolved, selectedCount: 1, hasSequence: true)
        XCTAssertEqual(single, ["Copy Name", "Copy Sequence"])
        // multi unresolved → Copy Names + Copy Sequences + Copy Rows
        let multi = TwelveSCopyMenuProvider.itemTitles(mode: .unresolved, selectedCount: 3, hasSequence: true)
        XCTAssertEqual(multi, ["Copy Names", "Copy Sequences", "Copy Rows"])
        // single target → Copy Name only
        XCTAssertEqual(TwelveSCopyMenuProvider.itemTitles(mode: .targets, selectedCount: 1, hasSequence: false), ["Copy Name"])
        // multi target → Copy Names + Copy Rows
        XCTAssertEqual(TwelveSCopyMenuProvider.itemTitles(mode: .targets, selectedCount: 2, hasSequence: false), ["Copy Names", "Copy Rows"])
        // single unresolved with empty sequence → Copy Sequence omitted
        XCTAssertEqual(TwelveSCopyMenuProvider.itemTitles(mode: .unresolved, selectedCount: 1, hasSequence: false), ["Copy Name"])
    }
}
