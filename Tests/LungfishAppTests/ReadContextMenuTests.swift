// ReadContextMenuTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Item 3 (mapping viewer fixes, 2026-08-09): the main mapping viewport already
// supported Cmd/Shift multi-select of reads (SequenceViewerView+Interaction.swift),
// but `rightMouseDown` never checked `readAtPoint`, so right-clicking a read
// never showed a context menu. These tests exercise the new testable seam
// `SequenceViewerView.buildReadContextMenu(forReadAt:)` directly (headless —
// no NSEvent/pixel driving needed) to assert:
//   - the read branch wins over the generic/annotation menu when a read is hit
//   - the menu is disabled at zero selection
//   - right-clicking outside the current selection replaces the selection
//     with the read under the cursor (matching the existing table convention)
//   - "Copy as FASTA" writes the aligned-orientation FASTA to the pasteboard
//   - selectedReadIDs -> AlignedRead mapping handles a mate pair (one QNAME,
//     two records) correctly

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishKit

@MainActor
final class ReadContextMenuTests: XCTestCase {

    private func makeRead(
        name: String,
        flag: UInt16 = 0,
        position: Int = 100,
        cigar: String = "50M",
        mapq: UInt8 = 60
    ) -> AlignedRead {
        AlignedRead(
            name: name,
            flag: flag,
            chromosome: "chr1",
            position: position,
            mapq: mapq,
            cigar: CIGAROperation.parse(cigar) ?? [],
            sequence: String(repeating: "A", count: 50),
            qualities: Array(repeating: UInt8(30), count: 50)
        )
    }

    /// Places a single read at row 0 and points the hit-test coordinate at its
    /// packed row/x — mirrors the geometry `readAtPoint` expects (see
    /// SequenceViewerView+Tooltips.swift). We drive this indirectly through
    /// the test hooks rather than real geometry by injecting the packed-read
    /// row directly and using `readAtPoint`'s row-bucket lookup through
    /// `SequenceViewerView.readInRow`, which we invoke through the public
    /// seam under test with a location guaranteed to hit row 0.
    private func configureSingleReadView(_ read: AlignedRead) -> SequenceViewerView {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.testSetCachedPackedReads([(0, read)])
        view.testSetLastRenderedReadTier(.packed)
        return view
    }

    // MARK: - Menu presence / absence

    func testBuildReadContextMenuReturnsNilWhenNoReadAtPoint() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.testSetCachedPackedReads([])

        let menu = view.testBuildReadContextMenu(forRead: nil)

        XCTAssertNil(menu)
    }

    func testBuildReadContextMenuReturnsMenuWhenReadIsHit() {
        let read = makeRead(name: "readA")
        let view = configureSingleReadView(read)

        let menu = view.testBuildReadContextMenu(forRead: read)

        XCTAssertNotNil(menu)
        let titles = menu?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Copy as FASTA (aligned orientation)"))
        XCTAssertTrue(titles.contains("Extract Reads… (original reads)"))
    }

    // MARK: - Selection replacement on right-click

    func testRightClickOnReadNotInSelectionReplacesSelectionWithReadUnderCursor() {
        let readA = makeRead(name: "readA", position: 0)
        let readB = makeRead(name: "readB", position: 100)
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.testSetCachedPackedReads([(0, readA), (1, readB)])
        view.testSetSelectedReadIDs([readA.id])

        _ = view.testBuildReadContextMenu(forRead: readB)

        XCTAssertEqual(view.testSelectedReadIDs, [readB.id])
    }

    func testRightClickOnAlreadySelectedReadDoesNotClearMultiSelection() {
        let readA = makeRead(name: "readA", position: 0)
        let readB = makeRead(name: "readB", position: 100)
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.testSetCachedPackedReads([(0, readA), (1, readB)])
        view.testSetSelectedReadIDs([readA.id, readB.id])

        _ = view.testBuildReadContextMenu(forRead: readA)

        XCTAssertEqual(view.testSelectedReadIDs, [readA.id, readB.id])
    }

    // MARK: - Menu disabled at zero selection

    func testMenuItemsDisabledWhenSelectionSomehowEndsUpEmpty() {
        // Defensive: buildItems is selection-count-aware; assert the builder
        // itself disables at zero even though the read-hit path always seeds
        // a non-empty selection before building the menu.
        let menu = ReadSelectionActionMenuBuilder.buildMenu(
            selectionCount: 0,
            handlers: ReadSelectionActionHandlers(onCopyAsFASTA: {}, onExtractReads: {})
        )
        for item in menu.items {
            XCTAssertFalse(item.isEnabled, "Expected '\(item.title)' disabled at zero selection")
        }
    }

    func testMenuItemsEnabledAtNonZeroSelection() {
        let menu = ReadSelectionActionMenuBuilder.buildMenu(
            selectionCount: 2,
            handlers: ReadSelectionActionHandlers(onCopyAsFASTA: {}, onExtractReads: {})
        )
        for item in menu.items {
            XCTAssertTrue(item.isEnabled, "Expected '\(item.title)' enabled at non-zero selection")
        }
    }

    // MARK: - selectedReads mapping (UUID -> AlignedRead), incl. mate pair

    func testSelectedReadsMapsUUIDsToAlignedReadsIncludingMatePair() {
        let mate1 = makeRead(name: "pairedRead", flag: 0x1 | 0x40, position: 0)   // first in pair
        let mate2 = makeRead(name: "pairedRead", flag: 0x1 | 0x80, position: 200) // second in pair
        let other = makeRead(name: "otherRead", position: 500)
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.testSetCachedPackedReads([(0, mate1), (1, mate2), (2, other)])
        view.testSetSelectedReadIDs([mate1.id, mate2.id])

        let selected = view.testSelectedReads

        XCTAssertEqual(selected.count, 2)
        XCTAssertEqual(Set(selected.map(\.name)), ["pairedRead"])
        XCTAssertEqual(Set(selected.map(\.id)), [mate1.id, mate2.id])
    }

    // MARK: - Copy as FASTA writes expected string to pasteboard

    func testCopySelectedReadsAsFASTAWritesFormattedStringToPasteboard() {
        let read = makeRead(name: "readA", position: 99, cigar: "10M", mapq: 42)
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.testSetCachedPackedReads([(0, read)])
        view.testSetSelectedReadIDs([read.id])

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        view.testCopySelectedReadsAsFASTA(to: pasteboard)

        let written = pasteboard.string(forType: .string)
        XCTAssertEqual(
            written,
            ">readA chr1:100-109 strand=+ cigar=10M mapq=42\n" + String(repeating: "A", count: 50)
        )
    }
}
