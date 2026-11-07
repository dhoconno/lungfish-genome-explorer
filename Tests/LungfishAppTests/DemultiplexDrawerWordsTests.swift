// DemultiplexDrawerWordsTests.swift - The Demux tab says what Demultiplex… does with its plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN, row DEMUX-SUMMARY-PROMISES-OUTPUTS (UX's D1c table, PASS-TABLE green row). The summary
// promised outputs from a plan no run read, and Save said no run reads it. With the plan wired, both say that
// Demultiplex… opens Demultiplex Barcodes with the plan.

import AppKit
import XCTest
import LungfishIO
@testable import LungfishApp

@MainActor
final class DemultiplexDrawerWordsTests: XCTestCase {
    private func texts(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    private func button(in view: NSView, where matches: (NSButton) -> Bool) -> NSButton? {
        if let button = view as? NSButton, matches(button) { return button }
        for subview in view.subviews {
            if let found = button(in: subview, where: matches) { return found }
        }
        return nil
    }

    private func button(titled title: String, in view: NSView) -> NSButton? {
        button(in: view) { $0.title == title }
    }

    func testDemuxTabSummaryDoesNotPromiseOutputs() {
        let drawer = FASTQMetadataDrawerView()
        drawer.selectDemuxTab()
        let words = texts(in: drawer)
        XCTAssertFalse(words.contains { $0.contains("Outputs will be created") }, "\(words)")
        XCTAssertTrue(
            words.contains("Demultiplex\u{2026} opens Demultiplex Barcodes with this plan. It makes one output for each sample in the table."),
            "\(words)"
        )
        XCTAssertNotNil(button(titled: "Demultiplex\u{2026}", in: drawer), "the Demux tab has no Demultiplex\u{2026} control")
    }

    func testDemuxTabSaveSaysDemultiplexRunsThePlan() throws {
        let drawer = FASTQMetadataDrawerView()
        drawer.selectDemuxTab()
        // Its title reads "Save" or "Save to Project Dataset" as the drawer's state changes, its label does not.
        try XCTUnwrap(button(in: drawer) { $0.accessibilityLabel() == "Save metadata" }).performClick(nil)
        let words = texts(in: drawer)
        XCTAssertFalse(words.contains { $0.contains("No demultiplexing run reads this plan") }, "\(words)")
        XCTAssertTrue(words.contains("Saved with this dataset. Demultiplex\u{2026} runs it."), "\(words)")
    }

    func testScoutProceedWordsNameTheRunThatReadsThePlan() {
        let words = ViewerViewController.scoutProceedWords(count: 3)
        XCTAssertFalse(words.contains("No run reads it"), words)
        XCTAssertTrue(words.contains("Demultiplex\u{2026}"), words)
    }
}
