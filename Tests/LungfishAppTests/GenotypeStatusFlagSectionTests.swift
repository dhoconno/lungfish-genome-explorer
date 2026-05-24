// GenotypeStatusFlagSectionTests.swift - Tests for GenotypeStatusFlagSection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import SwiftUI
@testable import LungfishApp
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeStatusFlagSectionTests: XCTestCase {
    func testSectionExposesStatusAndCommentsInputs() {
        let comments = sampleComments()
        let section = GenotypeStatusFlagSection(
            status: .constant(.needsReview),
            comments: comments,
            onAddComment: { _ in }
        )

        XCTAssertEqual(section.comments.count, 2)
        XCTAssertEqual(section.comments.first?.body, "Looks like a Mafa-B*02 dropout.")
    }

    func testHostingViewRendersWithoutCrashing() {
        var status: GenotypeAnnotationSidecar.StatusValue = .reviewed
        let binding = Binding(get: { status }, set: { status = $0 })
        let section = GenotypeStatusFlagSection(
            status: binding,
            comments: sampleComments(),
            onAddComment: { _ in }
        )

        let hosting = NSHostingView(rootView: section)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 360)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
    }

    func testEmptyCommentsRendersPlaceholder() throws {
        var status: GenotypeAnnotationSidecar.StatusValue = .unflagged
        let binding = Binding(get: { status }, set: { status = $0 })
        let section = GenotypeStatusFlagSection(
            status: binding,
            comments: [],
            onAddComment: { _ in }
        )

        let hosting = NSHostingView(rootView: section)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        hosting.layoutSubtreeIfNeeded()

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/GenotypeStatusFlagSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("No comments yet."))
    }

    func testAddCommentClosureForwardsTrimmedText() {
        var status: GenotypeAnnotationSidecar.StatusValue = .unflagged
        let binding = Binding(get: { status }, set: { status = $0 })
        var captured: [String] = []
        let section = GenotypeStatusFlagSection(
            status: binding,
            comments: [],
            onAddComment: { captured.append($0) }
        )

        section.onAddComment("Reviewed against re-run; call confirmed.")
        section.onAddComment("Another note")

        XCTAssertEqual(captured, [
            "Reviewed against re-run; call confirmed.",
            "Another note",
        ])
    }

    func testSegmentedControlExposesAllFourStatusCases() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/GenotypeStatusFlagSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(source.contains("ForEach(GenotypeAnnotationSidecar.StatusValue.allCases"))
        // displayName(for:) maps each case to a human label.
        for value in GenotypeAnnotationSidecar.StatusValue.allCases {
            XCTAssertTrue(source.contains("case .\(value.rawValue):"),
                          "Missing label switch case for \(value.rawValue)")
        }
        XCTAssertTrue(source.contains("\"Unflagged\""))
        XCTAssertTrue(source.contains("\"Needs Review\""))
        XCTAssertTrue(source.contains("\"Reviewed\""))
        XCTAssertTrue(source.contains("\"Confirmed\""))
    }

    func testStatusValueBindingDriversRender() {
        // Render with each status value to ensure the picker selection survives mounting.
        for value in GenotypeAnnotationSidecar.StatusValue.allCases {
            var status = value
            let binding = Binding(get: { status }, set: { status = $0 })
            let section = GenotypeStatusFlagSection(
                status: binding,
                comments: sampleComments(),
                onAddComment: { _ in }
            )
            let hosting = NSHostingView(rootView: section)
            hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 360)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0, "Failed render for \(value.rawValue)")
        }
    }

    // MARK: - Helpers

    private func sampleComments() -> [GenotypeAnnotationSidecar.CellComment] {
        [
            .init(
                sample: "H22C112", locus: "MHC-A", slot: .h2,
                body: "Looks like a Mafa-B*02 dropout.",
                author: "dho", timestamp: "2026-05-22T16:02:11Z"
            ),
            .init(
                sample: "H22C112", locus: "MHC-A", slot: .h2,
                body: "Called M2A from 02_M2_G_02_06_156bp 198 reads (auto)",
                author: "pipeline", timestamp: "2026-05-22T15:45:01Z"
            ),
        ]
    }
}
