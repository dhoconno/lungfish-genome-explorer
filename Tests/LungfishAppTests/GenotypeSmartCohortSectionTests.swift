// GenotypeSmartCohortSectionTests.swift - Tests for GenotypeSmartCohortSection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import SwiftUI
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeSmartCohortSectionTests: XCTestCase {
    func testSectionInstantiatesWithThreeCohortsAndExposesEachRow() {
        let cohorts = sampleCohorts()
        let section = GenotypeSmartCohortSection(
            cohorts: cohorts,
            onSelect: { _ in },
            onDelete: { _ in },
            onAdd: { }
        )

        // Each DisplayedCohort surfaces a stable identity composed of name and scope.
        XCTAssertEqual(section.cohorts.count, 3)
        XCTAssertEqual(section.cohorts.map(\.id), [
            "Needs Review/bundle",
            "Bw6+ carriers/user",
            "Homozygous A/bundle",
        ])
        XCTAssertEqual(section.cohorts.map(\.count), [7, 12, 3])
    }

    func testHostingViewRendersWithoutCrashingForThreeCohorts() {
        let section = GenotypeSmartCohortSection(
            cohorts: sampleCohorts(),
            onSelect: { _ in },
            onDelete: { _ in },
            onAdd: { }
        )

        let hosting = NSHostingView(rootView: section)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        hosting.layoutSubtreeIfNeeded()

        // Forcing the view tree to lay out exercises the SwiftUI body builder; an empty
        // bounds is fine but a non-zero fitting size indicates the section produced content.
        let fitting = hosting.fittingSize
        XCTAssertGreaterThan(fitting.height, 0)
        XCTAssertGreaterThan(fitting.width, 0)
    }

    func testSelectClosureFiresWithFilterForRow() {
        let cohorts = sampleCohorts()
        var captured: GenotypeCohortSmartFilter?
        let section = GenotypeSmartCohortSection(
            cohorts: cohorts,
            onSelect: { captured = $0 },
            onDelete: { _ in },
            onAdd: { }
        )

        // We invoke the closure directly here to confirm the section forwards the filter
        // it was configured with; NSHostingView synthetic clicks are not robust enough for
        // unit tests of nested SwiftUI buttons.
        section.onSelect(cohorts[1].filter)

        XCTAssertEqual(captured?.name, "Bw6+ carriers")
        XCTAssertEqual(captured?.scope, "user")
    }

    func testDeleteClosureFiresWithSelectedCohort() {
        let cohorts = sampleCohorts()
        var captured: GenotypeCohortSmartFilter?
        let section = GenotypeSmartCohortSection(
            cohorts: cohorts,
            onSelect: { _ in },
            onDelete: { captured = $0 },
            onAdd: { }
        )

        section.onDelete(cohorts[2].filter)

        XCTAssertEqual(captured?.name, "Homozygous A")
        XCTAssertEqual(captured?.scope, "bundle")
    }

    func testAddClosureFiresWhenInvoked() {
        var invocationCount = 0
        let section = GenotypeSmartCohortSection(
            cohorts: [],
            onSelect: { _ in },
            onDelete: { _ in },
            onAdd: { invocationCount += 1 }
        )

        section.onAdd()
        section.onAdd()

        XCTAssertEqual(invocationCount, 2)
    }

    func testEmptyCohortsRenderWithoutCrashing() {
        let section = GenotypeSmartCohortSection(
            cohorts: [],
            onSelect: { _ in },
            onDelete: { _ in },
            onAdd: { }
        )

        let hosting = NSHostingView(rootView: section)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    // MARK: - Helpers

    private func sampleCohorts() -> [GenotypeSmartCohortSection.DisplayedCohort] {
        [
            .init(
                filter: GenotypeCohortSmartFilter(
                    name: "Needs Review",
                    scope: "bundle",
                    isStarred: false,
                    predicate: .hasAnalystFlag(.needsReview)
                ),
                count: 7
            ),
            .init(
                filter: GenotypeCohortSmartFilter(
                    name: "Bw6+ carriers",
                    scope: "user",
                    isStarred: true,
                    predicate: .commentContains("Bw6")
                ),
                count: 12
            ),
            .init(
                filter: GenotypeCohortSmartFilter(
                    name: "Homozygous A",
                    scope: "bundle",
                    isStarred: false,
                    predicate: .isHomozygousAcrossAll
                ),
                count: 3
            ),
        ]
    }
}
