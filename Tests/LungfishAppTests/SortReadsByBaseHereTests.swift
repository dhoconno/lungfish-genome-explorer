// SortReadsByBaseHereTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Base at Position sorting existed in the renderer, but nothing ever set the
// position it sorts by, so choosing it changed nothing. These tests cover the
// two ways to set it: the read track's "Sort Reads by Base Here" (the clicked
// column) and the Inspector picker alone (the centre of the view).

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO

@MainActor
final class SortReadsByBaseHereTests: XCTestCase {

    private func viewerWithReads() -> SequenceViewerView {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.alignmentDataProviders = [(
            trackId: "track",
            provider: AlignmentDataProvider(alignmentPath: "/tmp/none.bam", indexPath: "/tmp/none.bam.bai")
        )]
        return view
    }

    private func sortItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == "Sort Reads by Base Here" }
    }

    func testAlignmentAndReadMenusOfferSortAtTheClickedColumn() throws {
        let view = viewerWithReads()
        let alignmentMenu = view.testBuildContextMenu(for: .alignment([]), genomicPosition: 2161)
        XCTAssertEqual(try XCTUnwrap(sortItem(in: alignmentMenu)).representedObject as? Int, 2161)

        let read = AlignedRead(
            name: "r", flag: 0, chromosome: "chr1", position: 2100, mapq: 60,
            cigar: [CIGAROperation(op: .match, length: 100)],
            sequence: String(repeating: "A", count: 100), qualities: Array(repeating: 30, count: 100)
        )
        let readMenu = view.testBuildContextMenu(for: .read(read), genomicPosition: 2161)
        XCTAssertNotNil(sortItem(in: readMenu))
    }

    func testMenuOmitsSortWithoutReads() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let menu = view.testBuildContextMenu(for: .alignment([]), genomicPosition: 2161)
        XCTAssertNil(sortItem(in: menu))
    }

    func testChoosingSortSetsModeAndPositionAndTellsTheInspector() throws {
        let view = viewerWithReads()
        let menu = view.testBuildContextMenu(for: .alignment([]), genomicPosition: 2161)
        let item = try XCTUnwrap(sortItem(in: menu))

        let posted = expectation(forNotification: .readSortPositionChosen, object: view) { note in
            note.userInfo?[NotificationUserInfoKey.readSortPosition] as? Int == 2161
        }
        view.sortReadsByBaseHereAction(item)
        wait(for: [posted], timeout: 1)

        XCTAssertEqual(view.readSortModeSetting, .baseAtPosition)
        XCTAssertEqual(view.readSortPositionSetting, 2161)
    }

    func testInspectorRecordsTheChosenColumnAndSendsItBack() {
        let vm = ReadStyleSectionViewModel()
        InspectorViewController.applyChosenReadSortPosition(2161, to: vm)
        XCTAssertEqual(vm.readSortMode, .baseAtPosition)
        XCTAssertEqual(vm.readSortPosition, 2161)

        let payload = InspectorViewController().makeReadDisplaySettingsPayload(from: vm)
        XCTAssertEqual(payload[NotificationUserInfoKey.readSortPosition] as? Int, 2161)
        XCTAssertEqual(payload[NotificationUserInfoKey.readSortMode] as? String, ReadSortMode.baseAtPosition.rawValue)
    }

    func testPayloadOmitsPositionWhenNoneWasChosen() {
        let payload = InspectorViewController().makeReadDisplaySettingsPayload(from: ReadStyleSectionViewModel())
        XCTAssertNil(payload[NotificationUserInfoKey.readSortPosition])
    }

    func testInspectorPickerAloneSortsAtTheCentreOfTheView() {
        let frame = ReferenceFrame(chromosome: "chr20", start: 2050, end: 2350, pixelWidth: 600, sequenceLength: 500_001)
        XCTAssertEqual(ViewerViewController.readSortCenterPosition(for: frame), 2200)

        let tail = ReferenceFrame(chromosome: "chr20", start: 500_000, end: 500_400, pixelWidth: 600, sequenceLength: 500_001)
        XCTAssertEqual(ViewerViewController.readSortCenterPosition(for: tail), 500_000, "clamped to the last base")
    }

    func testVoiceOverShowMenuOffersSortAtTheCentreColumn() throws {
        let controller = ViewerViewController()
        controller.loadView()
        let view: SequenceViewerView = controller.viewerView
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        controller.referenceFrame = ReferenceFrame(chromosome: "chr20", start: 2050, end: 2350, pixelWidth: 800, sequenceLength: 500_001)
        view.alignmentDataProviders = [(
            trackId: "track",
            provider: AlignmentDataProvider(alignmentPath: "/tmp/none.bam", indexPath: "/tmp/none.bam.bai")
        )]
        let menu = try XCTUnwrap(view.keyboardContextMenu())
        XCTAssertEqual(try XCTUnwrap(sortItem(in: menu)).representedObject as? Int, 2200)
    }
}
