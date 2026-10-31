// BlastResultsDrawerTabTests.swift - The empty BLAST results pane names the menu item every viewer has
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane 3E (UX-3E-LABELS D3, approved as O86). The empty pane told a person to choose
// "BLAST Matching Reads...", which only Kraken2 and CZ-ID had, and the contig pane named "BLAST Contig…", which no
// menu had. Both now name Verify with BLAST, the shared command title, and use no three-period ellipsis.

import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class BlastResultsDrawerTabTests: XCTestCase {

    func testEmptyTextNamesTheSharedItem() {
        let drawer = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 800, height: 250))
        let verification = Self.texts(in: drawer)
        XCTAssertTrue(verification.contains { $0.contains("Verify with BLAST") }, "\(verification)")
        XCTAssertFalse(verification.contains { $0.contains("...") }, "\(verification)")

        drawer.presentationStyle = .contigBlast
        let contig = Self.texts(in: drawer)
        XCTAssertTrue(contig.contains { $0.contains("Verify with BLAST") }, "\(contig)")
        XCTAssertFalse(contig.contains { $0.contains("...") }, "\(contig)")
        XCTAssertTrue(contig.contains { $0.contains("contig") }, "the contig pane names a contig, \(contig)")
    }

    /// A failure with no words of its own says what happened and what to try next (R14).
    func testEmptyFailureSaysWhatToTryNext() {
        let drawer = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: 800, height: 250))
        drawer.showFailure(message: "  ")
        XCTAssertTrue(
            Self.texts(in: drawer).contains(
                "NCBI BLAST did not return a result. Check the network connection, then choose Verify with BLAST again."
            ),
            "\(Self.texts(in: drawer))"
        )
    }

    private static func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { subview -> [String] in
            let own = (subview as? NSTextField).map { [$0.stringValue] } ?? []
            return own + texts(in: subview)
        }
    }
}
