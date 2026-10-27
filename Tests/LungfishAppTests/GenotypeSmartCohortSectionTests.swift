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
import LungfishTestSupport

@MainActor
final class GenotypeSmartCohortSectionTests: XCTestCase {
    func testDocumentStateEqualityIncludesHaplotypingCapability() {
        let genotypeOnly = documentState(hasHaplotypingResult: false)
        let haplotyped = documentState(hasHaplotypingResult: true)

        XCTAssertNotEqual(genotypeOnly, haplotyped)
    }

    func testDocumentLayoutOmitsSmartCohortsAndOnlyTheirAdjacentDividerWithoutHaplotypes() {
        let genotypeOnly = GenotypeResultDocumentSection(
            state: documentState(hasHaplotypingResult: false)
        )
        let haplotyped = GenotypeResultDocumentSection(
            state: documentState(hasHaplotypingResult: true)
        )

        XCTAssertEqual(
            genotypeOnly.testingVisibleComponents,
            [.header, .divider, .includedLoci, .divider, .summary, .divider, .samples,
             .divider, .qc, .divider, .artifacts]
        )
        XCTAssertEqual(
            haplotyped.testingVisibleComponents,
            [.header, .divider, .includedLoci, .divider, .smartCohorts, .divider,
             .summary, .divider, .samples, .divider, .qc, .divider, .artifacts]
        )
        XCTAssertFalse(genotypeOnly.testingSmartCohortActionsAvailable)
        XCTAssertTrue(haplotyped.testingSmartCohortActionsAvailable)
    }

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

    // MARK: - The active cohort (walk star 10)

    func testOnlyTheActiveRowShowsTheCheckmarkAndTheSelectedTrait() {
        let cohorts = GenotypeSmartCohortSection.marking(sampleCohorts(), active: sampleCohorts()[1].filter)
        let section = GenotypeSmartCohortSection(cohorts: cohorts, onSelect: { _ in }, onDelete: { _ in }, onAdd: { })

        XCTAssertEqual(section.activeCohortID, "Bw6+ carriers/user")
        XCTAssertEqual(cohorts.map(\.isActive), [false, true, false])
        let active = GenotypeSmartCohortSection.rowPresentation(for: cohorts[1])
        XCTAssertEqual(active, .init(
            showsCheckmark: true, isSelected: true, accessibilityLabel: "Bw6+ carriers",
            accessibilityValue: "Active, 12 samples", accessibilityHint: "Clears this cohort filter."
        ))
        let inactive = GenotypeSmartCohortSection.rowPresentation(for: cohorts[0])
        XCTAssertEqual(inactive, .init(
            showsCheckmark: false, isSelected: false, accessibilityLabel: "Needs Review",
            accessibilityValue: "7 samples", accessibilityHint: "Filters the viewer to this cohort."
        ))
    }

    func testMarkingMatchesTheActiveCohortByNameAndScopeAndNilClearsEveryMark() {
        let sameNameOtherScope = GenotypeCohortSmartFilter(
            name: "Needs Review", scope: "user", isStarred: false, predicate: .hasAnyComment
        )
        XCTAssertEqual(GenotypeSmartCohortSection.marking(sampleCohorts(), active: sameNameOtherScope).map(\.isActive), [false, false, false])
        let marked = GenotypeSmartCohortSection.marking(sampleCohorts(), active: sampleCohorts()[2].filter)
        XCTAssertEqual(marked.map(\.isActive), [false, false, true])
        XCTAssertEqual(GenotypeSmartCohortSection.marking(marked, active: nil).map(\.isActive), [false, false, false])
    }

    func testTheActiveRowReachesAssistiveTechnologyAsSelected() throws {
        let cohorts = GenotypeSmartCohortSection.marking(sampleCohorts(), active: sampleCohorts()[1].filter)
        let window = AccessibilityTreeProbe.host(
            GenotypeSmartCohortSection(cohorts: cohorts, onSelect: { _ in }, onDelete: { _ in }, onAdd: { }),
            size: CGSize(width: 320, height: 260)
        )
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        var activeRow: NSObject?
        AccessibilityTreeProbe.waitUntil {
            activeRow = AccessibilityTreeProbe.elements(in: root, labelled: "Bw6+ carriers").first
            return activeRow != nil
        }

        let row = try XCTUnwrap(activeRow, AccessibilityTreeProbe.dump(root))
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(row))
        XCTAssertEqual(AccessibilityTreeProbe.value(row), "Active, 12 samples")
        let other = try XCTUnwrap(AccessibilityTreeProbe.elements(in: root, labelled: "Needs Review").first)
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(other))
    }

    // MARK: - The delete buttons (walk WO-7)

    /// Each delete button names its cohort. The four buttons of the built-in cohorts all read "Remove" to VoiceOver, and
    /// their tooltip said "Delete cohort" without saying which one.
    func testEachDeleteButtonNamesItsCohortToAssistiveTechnologyAndInItsTooltip() throws {
        let cohorts = sampleCohorts()
        let window = AccessibilityTreeProbe.host(
            GenotypeSmartCohortSection(cohorts: cohorts, onSelect: { _ in }, onDelete: { _ in }, onAdd: { }),
            size: CGSize(width: 320, height: 320)
        )
        defer { window.orderOut(nil) }
        let root = try XCTUnwrap(window.contentView)
        func deleteButtons() -> [NSObject] {
            AccessibilityTreeProbe.all(in: root).filter {
                AccessibilityTreeProbe.identifier($0) == "genotypeSmartCohortDeleteButton"
            }
        }
        AccessibilityTreeProbe.waitUntil { deleteButtons().count == cohorts.count }

        let buttons = deleteButtons()
        XCTAssertEqual(buttons.count, cohorts.count, AccessibilityTreeProbe.dump(root))
        XCTAssertEqual(
            buttons.map { AccessibilityTreeProbe.label($0) ?? "" },
            ["Remove Needs Review", "Remove Bw6+ carriers", "Remove Homozygous A"]
        )
        XCTAssertEqual(
            buttons.map { AccessibilityTreeProbe.help($0) ?? "" },
            ["Delete the Needs Review cohort", "Delete the Bw6+ carriers cohort", "Delete the Homozygous A cohort"]
        )
    }

    // MARK: - Restore Built-In Cohorts (plan decision S13)

    func testRestoreIsOfferedOnlyWhenABuiltInCohortIsMissing() {
        let builtIns = GenotypeAnnotationStore.builtInSmartCohorts
        let all = GenotypeSmartCohortSection.displayedCohorts(builtIns, subjects: [])
        let lacking = all.filter { $0.filter.name != "Homozygous" }
        var restores = 0

        XCTAssertEqual(
            GenotypeSmartCohortSection(cohorts: all, onSelect: { _ in }, onDelete: { _ in }, onAdd: { }).restorableBuiltInNames,
            []
        )
        let section = GenotypeSmartCohortSection(
            cohorts: lacking, onSelect: { _ in }, onDelete: { _ in }, onAdd: { },
            onRestoreBuiltIns: { restores += 1 }
        )
        XCTAssertEqual(section.restorableBuiltInNames, ["Homozygous"])
        section.onRestoreBuiltIns?()
        XCTAssertEqual(restores, 1)
    }

    func testTheRestoreButtonAppearsWithAMissingBuiltInAndAnAction() throws {
        let lacking = GenotypeSmartCohortSection.displayedCohorts(
            GenotypeAnnotationStore.builtInSmartCohorts.filter { $0.name != "Recombinants" }, subjects: []
        )
        let offered = AccessibilityTreeProbe.host(
            GenotypeSmartCohortSection(cohorts: lacking, onSelect: { _ in }, onDelete: { _ in }, onAdd: { }, onRestoreBuiltIns: { }),
            size: CGSize(width: 320, height: 320)
        )
        let withoutAction = AccessibilityTreeProbe.host(
            GenotypeSmartCohortSection(cohorts: lacking, onSelect: { _ in }, onDelete: { _ in }, onAdd: { }),
            size: CGSize(width: 320, height: 320)
        )
        let full = AccessibilityTreeProbe.host(
            GenotypeSmartCohortSection(
                cohorts: GenotypeSmartCohortSection.displayedCohorts(GenotypeAnnotationStore.builtInSmartCohorts, subjects: []),
                onSelect: { _ in }, onDelete: { _ in }, onAdd: { }, onRestoreBuiltIns: { }
            ),
            size: CGSize(width: 320, height: 320)
        )
        defer {
            offered.orderOut(nil)
            withoutAction.orderOut(nil)
            full.orderOut(nil)
        }
        let offeredRoot = try XCTUnwrap(offered.contentView)
        var button: NSObject?
        AccessibilityTreeProbe.waitUntil {
            button = AccessibilityTreeProbe.element(in: offeredRoot, identifier: "genotypeSmartCohortRestoreButton")
            return button != nil
        }

        XCTAssertNotNil(button, AccessibilityTreeProbe.dump(offeredRoot))
        XCTAssertTrue(isAccessibilityEnabled(try XCTUnwrap(button)))
        let otherRoot = try XCTUnwrap(withoutAction.contentView)
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: otherRoot, identifier: "genotypeSmartCohortAddButton") != nil
        }
        XCTAssertNil(AccessibilityTreeProbe.element(in: otherRoot, identifier: "genotypeSmartCohortRestoreButton"))
        // With every built-in listed the button stays, disabled, so focus never drops and the undo stays visible.
        let fullRoot = try XCTUnwrap(full.contentView)
        var disabled: NSObject?
        AccessibilityTreeProbe.waitUntil {
            disabled = AccessibilityTreeProbe.element(in: fullRoot, identifier: "genotypeSmartCohortRestoreButton")
            return disabled != nil
        }
        let fullButton = try XCTUnwrap(disabled, AccessibilityTreeProbe.dump(fullRoot))
        XCTAssertFalse(isAccessibilityEnabled(fullButton))
    }

    // MARK: - Inspector wiring

    func testTheInspectorMarksTheViewersActiveCohortAndKeepsTheMarkThroughASidecarChange() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-active-cohort-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = GenotypeTestFixtures.makeResult(
            bundleURL: bundleURL,
            calls: [],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "MHC-exon2-miSeq", definitionSetID: "definitions",
                definitionSetName: "Definitions", speciesName: "Test macaque", samples: []
            )
        )
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.viewModel.contentMode = .genotype
        inspector.updateGenotypeResultDocument(result)
        func marks() -> [String] {
            (inspector.viewModel.documentSectionViewModel.genotypeResultDocument?.smartCohorts ?? [])
                .filter(\.isActive).map(\.filter.name)
        }
        XCTAssertEqual(marks(), [])
        let needsReview = try XCTUnwrap(GenotypeAnnotationStore.builtInSmartCohorts.first { $0.name == "Needs review" })

        inspector.updateGenotypeActiveSmartCohort(needsReview)
        XCTAssertEqual(marks(), ["Needs review"])

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-01T00:00:00Z")
        sidecar.smartCohorts = GenotypeAnnotationStore.builtInSmartCohorts
        inspector.updateGenotypeAnnotationSidecar(sidecar)
        XCTAssertEqual(marks(), ["Needs review"])

        inspector.updateGenotypeActiveSmartCohort(nil)
        XCTAssertEqual(marks(), [])

        // A rebuild, such as the one after an AI haplotyping run, keeps the viewer's mark it is handed.
        inspector.updateGenotypeResultDocument(result, activeSmartCohort: needsReview)
        XCTAssertEqual(marks(), ["Needs review"])
    }

    // MARK: - Helpers

    /// SwiftUI's accessibility nodes speak the informal protocol, as `AccessibilityTreeProbe` reads them.
    private func isAccessibilityEnabled(_ element: NSObject) -> Bool {
        if let enabled = (element as AnyObject).isAccessibilityEnabled?() { return enabled }
        return (element.accessibilityAttributeValue(.enabled) as? Bool) ?? true
    }

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

    private func documentState(
        hasHaplotypingResult: Bool
    ) -> GenotypeResultDocumentState {
        GenotypeResultDocumentState(
            title: "Result",
            sampleIds: ["AnimalA"],
            summaryRows: [],
            qcRows: [],
            artifactRows: [],
            hasHaplotypingResult: hasHaplotypingResult,
            smartCohorts: sampleCohorts()
        )
    }
}
