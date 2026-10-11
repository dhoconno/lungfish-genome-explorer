// ProvenanceRawJSONDisplayTests.swift - The Raw JSON pane says when it cuts, caps or substitutes the text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp

/// The Provenance tab never shows an empty or unlabelled view of an existing record (UX
/// non-negotiable 2). The pane cuts a long record at 80 lines, says so, and says Copy takes the
/// whole record. These cases drive the real `ProvenanceSection` through ViewInspector, so they
/// need no window and run with the screen locked.
@MainActor
final class ProvenanceRawJSONDisplayTests: XCTestCase {
    // MARK: - The 80-line cut

    /// A record of `count` lines in the shape `ProvenanceJSON.encoder` writes, with no final newline.
    private func record(lines count: Int) -> String {
        (0..<count).map { index in
            switch index {
            case 0: return "{"
            case count - 1: return "}"
            default: return "  \"key-\(index)\" : \(index),"
            }
        }.joined(separator: "\n")
    }

    private func pane(of viewModel: ProvenanceInspectorViewModel) throws -> SelectableWrappingText {
        try ProvenanceSection(viewModel: viewModel).inspect()
            .find(ViewType.View<SelectableWrappingText>.self)
            .actualView()
    }

    /// The captions the pane lists above its text, in order. Each caption is a Text with the
    /// `provenance-raw-json-caption` identifier.
    private func captions(of viewModel: ProvenanceInspectorViewModel) -> [String] {
        guard let inspected = try? ProvenanceSection(viewModel: viewModel).inspect() else { return [] }
        return inspected
            .findAll(ViewType.Text.self, where: {
                (try? $0.accessibilityIdentifier()) == "provenance-raw-json-caption"
            })
            .compactMap { try? $0.string() }
    }

    func testARecordPastEightyLinesSaysHowManyLinesTheCutShowsAndThatCopyTakesAll() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.rawJSON = record(lines: 412)

        XCTAssertEqual(
            captions(of: viewModel),
            ["Showing the first 80 of 412 lines. Copy takes the whole record."]
        )
        let shown = try pane(of: viewModel).text
        XCTAssertEqual(shown.split(separator: "\n", omittingEmptySubsequences: false).count, 80)
        XCTAssertTrue(viewModel.rawJSON.hasPrefix(shown), "The pane shows the start of the record.")
        XCTAssertNil(
            try pane(of: viewModel).maximumNumberOfLines,
            "The cut is made on lines of the record, so the text view cuts nothing of its own."
        )
    }

    func testARecordOfEightyLinesOrFewerIsShownWholeWithoutACaption() throws {
        for count in [1, 79, 80] {
            let viewModel = ProvenanceInspectorViewModel()
            viewModel.rawJSON = record(lines: count)

            XCTAssertEqual(captions(of: viewModel), [], "\(count) lines are all shown.")
            XCTAssertEqual(try pane(of: viewModel).text, viewModel.rawJSON, "\(count) lines")
        }
    }

    func testAFinalNewlineIsNotACountedLine() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.rawJSON = record(lines: 80) + "\n"
        XCTAssertEqual(captions(of: viewModel), [], "80 lines and a final newline are 80 lines.")

        viewModel.rawJSON = record(lines: 81) + "\n"
        XCTAssertEqual(
            captions(of: viewModel),
            ["Showing the first 80 of 81 lines. Copy takes the whole record."]
        )
    }

    func testAnUnbrokenRecordPastTheCharacterLimitSaysHowMuchTheCutShows() throws {
        let viewModel = ProvenanceInspectorViewModel()
        let whole = "{\"stderr\":\"" + String(repeating: "x", count: 59_000) + "\"}"
        viewModel.rawJSON = whole

        XCTAssertEqual(
            captions(of: viewModel),
            ["Showing the first 20000 of \(whole.count) characters. Copy takes the whole record."]
        )
        XCTAssertEqual(try pane(of: viewModel).text.count, 20_000)
        XCTAssertTrue(whole.hasPrefix(try pane(of: viewModel).text))
    }

    func testCopyTakesTheWholeRecordNotTheLinesShown() throws {
        let viewModel = ProvenanceInspectorViewModel()
        let whole = record(lines: 412)
        viewModel.rawJSON = whole
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        viewModel.pasteboard = pasteboard

        try ProvenanceSection(viewModel: viewModel).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-copy-json")
            .button()
            .tap()

        XCTAssertEqual(pasteboard.string(forType: .string), whole)
        XCTAssertEqual(pasteboard.string(forType: .string)?.split(separator: "\n").count, 412)
    }
}
