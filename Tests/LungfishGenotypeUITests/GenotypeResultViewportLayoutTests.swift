import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Sample curation workbench layout and call-support check
@MainActor
final class GenotypeResultViewportLayoutTests: GenotypeResultViewportTestCase {
    func testSampleCurationWorkbenchUsesHysteresisAcrossViewportWidths() {
        let workbench = makeSampleCurationWorkbench()

        workbench.frame.size = NSSize(width: 968, height: 700)
        XCTAssertEqual(workbench.layoutMode, .stacked)

        workbench.frame.size = NSSize(width: 1_000, height: 700)
        XCTAssertEqual(workbench.layoutMode, .sideBySide)

        workbench.frame.size = NSSize(width: 980, height: 700)
        XCTAssertEqual(workbench.layoutMode, .sideBySide)

        workbench.frame.size = NSSize(width: 968, height: 700)
        XCTAssertEqual(workbench.layoutMode, .stacked)
    }


    func testSampleCurationWorkbenchRetainsInjectedChildViewIdentities() {
        let header = NSView()
        let assignment = NSView()
        let evidence = NSView()
        let workbench = GenotypeSampleCurationWorkbenchView(
            headerView: header,
            assignmentView: assignment,
            evidenceView: evidence
        )

        workbench.frame.size = NSSize(width: 1_000, height: 700)
        workbench.frame.size = NSSize(width: 968, height: 700)
        workbench.frame.size = NSSize(width: 1_000, height: 700)

        XCTAssertTrue(workbench.headerView === header)
        XCTAssertTrue(workbench.assignmentView === assignment)
        XCTAssertTrue(workbench.evidenceView === evidence)
        XCTAssertFalse(header.translatesAutoresizingMaskIntoConstraints)
        XCTAssertFalse(assignment.translatesAutoresizingMaskIntoConstraints)
        XCTAssertFalse(evidence.translatesAutoresizingMaskIntoConstraints)
    }


    func testSampleCurationWorkbenchDoesNotOwnScrolling() {
        let workbench = makeSampleCurationWorkbench()

        XCTAssertNil(workbench.firstDescendant(ofType: NSScrollView.self))
    }


    func testSampleCurationWorkbenchTypographyScaleRaisesSideBySideThreshold() {
        let workbench = makeSampleCurationWorkbench(typographyScale: 2)

        workbench.frame.size = NSSize(width: 1_239, height: 700)

        XCTAssertEqual(workbench.layoutMode, .stacked)

        workbench.frame.size = NSSize(width: 1_241, height: 700)

        XCTAssertEqual(workbench.layoutMode, .sideBySide)
    }


    func testSampleCurationWorkbenchLiveTypographyScaleReevaluatesCurrentWidth() {
        let workbench = makeSampleCurationWorkbench(typographyScale: 1)
        workbench.frame.size = NSSize(width: 1_000, height: 700)
        XCTAssertEqual(workbench.layoutMode, .sideBySide)

        workbench.updateContentTypographyScale(2)
        XCTAssertEqual(workbench.layoutMode, .stacked)

        workbench.updateContentTypographyScale(1)
        XCTAssertEqual(workbench.layoutMode, .sideBySide)
    }


    func testSampleCurationWorkbenchSuppliesFiniteEvidenceHeight() {
        let header = FixedViewportIntrinsicView(height: 120)
        let assignments = FixedViewportIntrinsicView(height: 360)
        let evidence = EvidenceAvailableHeightSpy()
        let workbench = GenotypeSampleCurationWorkbenchView(
            headerView: header,
            assignmentView: assignments,
            evidenceView: evidence
        )

        workbench.frame.size = NSSize(width: 1_000, height: 700)
        XCTAssertEqual(workbench.layoutMode, .sideBySide)
        XCTAssertEqual(evidence.availableHeight, 568, accuracy: 1)
        XCTAssertFalse(evidence.usesCompactHeight)

        workbench.frame.size = NSSize(width: 700, height: 500)
        XCTAssertEqual(workbench.layoutMode, .stacked)
        XCTAssertEqual(evidence.availableHeight, 368, accuracy: 1)
        XCTAssertTrue(evidence.usesCompactHeight)
    }


    func testSampleCurationWorkbenchStackedModeUsesRequiredFillWidthEqualities() {
        let workbench = makeSampleCurationWorkbench()
        workbench.frame.size = NSSize(width: 700, height: 700)

        workbench.layoutSubtreeIfNeeded()

        XCTAssertEqual(workbench.headerView.frame.width, workbench.frame.width, accuracy: 0.5)
        XCTAssertEqual(workbench.assignmentView.frame.width, workbench.frame.width, accuracy: 0.5)
        XCTAssertEqual(workbench.evidenceView.frame.width, workbench.frame.width, accuracy: 0.5)

        let identifiers = Set(
            constraintsInHierarchy(workbench)
                .filter { $0.isActive && $0.priority == .required }
                .compactMap(\.identifier)
        )
        XCTAssertTrue(identifiers.contains("GenotypeSampleCurationWorkbench.headerWidth"))
        XCTAssertTrue(identifiers.contains("GenotypeSampleCurationWorkbench.bodyWidth"))
        XCTAssertTrue(identifiers.contains("GenotypeSampleCurationWorkbench.assignmentWidth"))
        XCTAssertTrue(identifiers.contains("GenotypeSampleCurationWorkbench.evidenceWidth"))
    }


    func testWideWorkbenchFillsAvailableWidthWithoutEditorCapOrDeadCenterGap() {
        let workbench = makeSampleCurationWorkbench()
        workbench.frame.size = NSSize(width: 2_240, height: 700)

        workbench.layoutSubtreeIfNeeded()

        XCTAssertEqual(workbench.layoutMode, .sideBySide)
        XCTAssertGreaterThanOrEqual(workbench.assignmentView.frame.width, 519.5)
        XCTAssertGreaterThanOrEqual(workbench.evidenceView.frame.width, 359.5)
        XCTAssertEqual(
            workbench.assignmentView.frame.width
                + workbench.evidenceView.frame.width
                + 16,
            workbench.frame.width,
            accuracy: 1
        )
        XCTAssertEqual(
            workbench.evidenceView.frame.width / (workbench.bounds.width - 16),
            0.38,
            accuracy: 0.02
        )
        XCTAssertLessThan(
            workbench.evidenceView.frame.minX
                - workbench.assignmentView.frame.maxX,
            17
        )
    }


    func testCallSupportCheckStatesAndExplanationMatchThresholdContract() {
        XCTAssertEqual(
            GenotypeCallSupportCheck.evaluate(
                callCount: 1,
                retainedReads: 1_000,
                alignments: 20
            ),
            .meetsThresholds
        )
        XCTAssertEqual(
            GenotypeCallSupportCheck.evaluate(
                callCount: 1,
                retainedReads: 999,
                alignments: 20
            ),
            .lowSupport
        )
        XCTAssertEqual(
            GenotypeCallSupportCheck.evaluate(
                callCount: 1,
                retainedReads: 1_000,
                alignments: 19
            ),
            .lowSupport
        )
        XCTAssertEqual(
            GenotypeCallSupportCheck.evaluate(
                callCount: 0,
                retainedReads: 1_000,
                alignments: 20
            ),
            .reviewNeeded
        )
        XCTAssertEqual(
            GenotypeCallSupportCheck.meetsThresholds.title,
            "Meets thresholds"
        )
        XCTAssertTrue(
            GenotypeCallSupportCheck.meetsThresholds.explanation.contains(
                "not analyst approval or confirmation that haplotype assignments are correct"
            )
        )
        let header = GenotypeSampleCurationHeaderView(
            metrics: [
                .init(
                    label: "Call-support check",
                    value: GenotypeCallSupportCheck.meetsThresholds.title,
                    accessibilityHelp:
                        GenotypeCallSupportCheck.meetsThresholds.explanation
                ),
            ],
            explanation:
                GenotypeCallSupportCheck.meetsThresholds.explanation,
            typographyScale: 1
        )
        XCTAssertEqual(
            header.explanationField?.stringValue,
            GenotypeCallSupportCheck.meetsThresholds.explanation
        )
        XCTAssertEqual(
            header.explanationField?.accessibilityHelp(),
            GenotypeCallSupportCheck.meetsThresholds.explanation
        )
        XCTAssertEqual(
            header.metricFields[0].value.accessibilityHelp(),
            GenotypeCallSupportCheck.meetsThresholds.explanation
        )
    }


    func testSampleCurationHeaderUsesLiveResolvedContentTypographyFonts() {
        let notifications = NotificationCenter()
        let preference = MutableGenotypeTextSizePreference(.custom(100))
        let provider = MutableGenotypePreferredFonts(pointSize: 13)
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let header = GenotypeSampleCurationHeaderView(
            metrics: [
                .init(
                    label: "Call-support check",
                    value: "Meets thresholds",
                    emphasized: true
                ),
            ],
            explanation: "Automated support explanation",
            typographyScale: 1,
            typographyModel: typography
        )

        XCTAssertEqual(header.metricFields[0].label.font?.pointSize, 13)
        XCTAssertEqual(header.metricFields[0].value.font?.pointSize, 13)
        XCTAssertEqual(header.explanationField?.font?.pointSize, 13)

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)
        header.updateContentTypographyScale(2)

        XCTAssertEqual(header.metricFields[0].label.font?.pointSize, 26)
        XCTAssertEqual(header.metricFields[0].value.font?.pointSize, 26)
        XCTAssertEqual(header.explanationField?.font?.pointSize, 26)
    }

}
