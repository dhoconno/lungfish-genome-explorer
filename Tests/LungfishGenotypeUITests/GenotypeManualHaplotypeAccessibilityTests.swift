import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypeAccessibilityTests: XCTestCase {
    func testDisclosureNamesManualHaplotypesSevenLociAndExplainsRows()
        throws
    {
        let view = GenotypeManualHaplotypePinnedBandView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 176)
        )
        let button = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSButton }.first
        )

        XCTAssertEqual(button.title, "Manual haplotypes (7 loci)")
        XCTAssertEqual(
            button.accessibilityLabel(),
            "Manual haplotypes (7 loci)"
        )
        XCTAssertEqual(
            button.accessibilityHelp(),
            "Shows seven locus-level manual haplotype assignment rows below the sample names."
        )
        XCTAssertEqual(
            view.subviews.filter { $0.isAccessibilityElement() }.count,
            1,
            "The disclosure triangle and label must form one hit and focus target."
        )
    }

    func testDisclosureIsKeyboardFocusableAndAccessibilityOperable() throws {
        let view = GenotypeManualHaplotypePinnedBandView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 176)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSButton }.first
        )
        var reportedExpansion: Bool?
        view.onDisclosureChanged = { reportedExpansion = $0 }

        XCTAssertEqual(
            button.accessibilityIdentifier(),
            "manual-haplotype-band-disclosure"
        )
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(
            button.accessibilityLabel(),
            "Manual haplotypes (7 loci)"
        )
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.isAccessibilityExpanded(), true)
        XCTAssertEqual(
            (button.accessibilityValue() as? NSNumber)?.boolValue,
            true
        )
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(window.firstResponder === button)

        XCTAssertTrue(button.accessibilityPerformPress())

        XCTAssertEqual(reportedExpansion, false)
        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(button.isAccessibilityExpanded(), false)
        XCTAssertEqual(
            (button.accessibilityValue() as? NSNumber)?.boolValue,
            false
        )
    }

    func testDisclosureRespondsToSpaceReturnAndAccessibilityPress() throws {
        let view = GenotypeManualHaplotypePinnedBandView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 176)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSButton }.first
        )
        XCTAssertTrue(window.makeFirstResponder(button))

        button.keyDown(withCharacters: " ", keyCode: 49, in: window)
        XCTAssertEqual(button.state, .off)

        button.keyDown(withCharacters: "\r", keyCode: 36, in: window)
        XCTAssertEqual(button.state, .on)

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(button.state, .off)
    }

    func testDisclosureLabelWrapsAtTwoHundredPercentTextWithoutClipping()
        throws
    {
        let view = GenotypeManualHaplotypePinnedBandView(
            frame: NSRect(x: 0, y: 0, width: 280, height: 68)
        )
        view.font = .systemFont(ofSize: 26)
        view.rowHeight = 68
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSButton }.first
        )

        XCTAssertEqual(button.cell?.lineBreakMode, .byWordWrapping)
        XCTAssertFalse(button.cell?.usesSingleLineMode ?? true)
        XCTAssertEqual(
            try XCTUnwrap(button.font).pointSize,
            26,
            accuracy: 0.1
        )
        XCTAssertLessThanOrEqual(
            button.cell?.cellSize(forBounds: button.bounds).height ?? .greatestFiniteMagnitude,
            button.bounds.height
        )
    }

    func testBandCellsRemainNonFocusableAndExposeColumnSummaryThroughHeader()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let snapshot = GenotypeManualHaplotypeAssignmentBandSnapshot(
            index: GenotypeManualHaplotypeAssignmentIndex(
                assignments: fixture.assignments
            ),
            samples: fixture.samples
        )
        let view = GenotypeManualHaplotypeSampleBandView(
            frame: NSRect(x: 0, y: 0, width: 1_320, height: 176)
        )
        view.snapshot = snapshot

        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertEqual(
            view.subviews.compactMap { $0 as? NSControl }.count,
            0
        )
        XCTAssertEqual(view.isAccessibilityElement(), false)
        let summary = try XCTUnwrap(
            snapshot.accessibilitySummaryBySample[fixture.samples[0]]
        )
        XCTAssertTrue(summary.hasPrefix("Manual haplotypes:"))
        for locus in GenotypeManualHaplotypeLocus.allCases {
            XCTAssertTrue(summary.contains(locus.workbookLabel))
        }
    }

    func testFourteenEditorSlotsAndClearActionsHaveUniqueLocusSlotLabels() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: fixture.assignments
        )
        let draft = GenotypeManualHaplotypeDraft(
            sample: fixture.samples[0],
            index: index
        )
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: .init(
                draft: draft,
                copyCandidates: fixture.samples.dropFirst().prefix(3).map {
                    index.sampleAssignments(for: $0)
                },
                isReadOnly: false
            ),
            onSave: { _ in draft },
            onReload: {
                .init(
                    draft: draft,
                    copyCandidates: [],
                    isReadOnly: false
                )
            },
            onExport: {}
        )
        let slots = model.rows.flatMap { [$0.h1, $0.h2] }

        XCTAssertEqual(slots.count, 14)
        XCTAssertEqual(Set(slots.map(\.accessibilityIdentifier)).count, 14)
        XCTAssertEqual(Set(slots.map(\.accessibilityLabel)).count, 14)
        XCTAssertEqual(Set(slots.map(\.clearAccessibilityLabel)).count, 14)
        XCTAssertTrue(
            slots.allSatisfy {
                $0.accessibilityLabel.contains($0.locus.workbookLabel)
                    && $0.accessibilityLabel.contains(
                        $0.slot == .h1 ? "H1" : "H2"
                    )
            }
        )
    }

    func testInvalidHostedComboExposesValidationAsActualAccessibilityHelp()
        throws
    {
        let draft = GenotypeManualHaplotypeDraft(
            sample: "Animal-1",
            index: GenotypeManualHaplotypeAssignmentIndex(assignments: [])
        )
        let snapshot = GenotypeManualHaplotypeEditorModel.Snapshot(
            draft: draft,
            copyCandidates: [],
            isReadOnly: false
        )
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: snapshot,
            onSave: { $0 },
            onReload: { snapshot },
            onExport: {}
        )
        model.updateLabel(
            String(repeating: "x", count: 129),
            locus: .a,
            slot: .h1
        )
        let expectedHelp = try XCTUnwrap(
            model.rows[0].h1.validationDescription
        )
        let host = makeGenotypeManualHaplotypeEditorHostingView(
            model: model,
            typographyModel: .shared
        )
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 1_600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        let combo = try XCTUnwrap(
            descendants(of: host)
                .compactMap { $0 as? NSComboBox }
                .first {
                    $0.accessibilityIdentifier()
                        == "manual-haplotype-MHC-A-h1"
                }
        )

        XCTAssertEqual(combo.accessibilityHelp(), expectedHelp)
        XCTAssertEqual(combo.accessibilityLabel(), "MHC-A H1 haplotype label")
    }

    func testCopyPickerReportsCompletenessAndMultiSelectionIsBounded() {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: fixture.assignments
        )
        let draft = GenotypeManualHaplotypeDraft(
            sample: fixture.samples[0],
            index: index
        )
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: .init(
                draft: draft,
                copyCandidates: fixture.samples.dropFirst().map {
                    index.sampleAssignments(for: $0)
                },
                isReadOnly: false
            ),
            onSave: { _ in draft },
            onReload: {
                .init(
                    draft: draft,
                    copyCandidates: [],
                    isReadOnly: false
                )
            },
            onExport: {}
        )
        let presentation =
            GenotypeManualHaplotypeMultiSamplePresentation(
                samples: fixture.samples
            )

        XCTAssertEqual(model.copyCandidates.count, 99)
        XCTAssertTrue(
            model.copyCandidates.allSatisfy {
                $0.completenessSummary == "14 of 14 assigned"
                    && $0.accessibilityLabel.contains("14 of 14 assigned")
            }
        )
        XCTAssertEqual(presentation.visibleSamples.count, 12)
        XCTAssertEqual(
            presentation.visibleSamples,
            Array(fixture.samples.prefix(12))
        )
        XCTAssertEqual(presentation.omittedSampleCount, 88)
        XCTAssertEqual(
            presentation.omissionSummary,
            "88 additional selected samples are not shown."
        )
    }

    func testMountedEditorUsesBoundedCopyPopoverAndOverflowExport()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: fixture.assignments
        )
        let draft = GenotypeManualHaplotypeDraft(
            sample: fixture.samples[0],
            index: index
        )
        var exportCount = 0
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: .init(
                draft: draft,
                copyCandidates: [
                    index.sampleAssignments(for: fixture.samples[1]),
                ],
                isReadOnly: false
            ),
            onSave: { $0 },
            onReload: {
                .init(
                    draft: draft,
                    copyCandidates: [],
                    isReadOnly: false
                )
            },
            onExport: { exportCount += 1 }
        )
        let host = makeGenotypeManualHaplotypeEditorHostingView(
            model: model,
            typographyModel: .shared
        )
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 1_600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        flush(host)

        let buttons = descendants(of: host).compactMap { $0 as? NSButton }
        let copyButton = try XCTUnwrap(
            buttons.first {
                $0.accessibilityIdentifier()
                    == "manual-haplotype-copy-picker"
            }
        )
        let moreActions = try XCTUnwrap(
            descendants(of: host)
                .compactMap { $0 as? NSPopUpButton }
                .first {
                    $0.accessibilityIdentifier()
                        == "manual-haplotype-more-actions"
                }
        )
        XCTAssertNil(
            buttons.first {
                $0.title == "Export All Manual Definitions…"
                    || $0.title == "Export Manual Definitions…"
            },
            "Analysis-wide export must not be a footer peer of sample Save."
        )
        let exportItem = try XCTUnwrap(
            moreActions.menu?.items.first {
                $0.title == "Export All Manual Definitions…"
            }
        )
        let exportAction = try XCTUnwrap(exportItem.action)
        XCTAssertTrue(
            NSApp.sendAction(
                exportAction,
                to: exportItem.target,
                from: exportItem
            )
        )
        XCTAssertEqual(exportCount, 1)

        let inlineHeight = host.fittingSize.height
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        copyButton.performClick(nil)
        let popoverWindow = try XCTUnwrap(
            waitForWindow(excluding: existingWindows)
        )
        defer {
            popoverWindow.close()
            RunLoop.main.run(
                until: Date(timeIntervalSinceNow: 0.08)
            )
        }
        let popoverContent = try XCTUnwrap(popoverWindow.contentView)
        XCTAssertNotEqual(popoverWindow, window)
        XCTAssertEqual(host.fittingSize.height, inlineHeight, accuracy: 1)
        XCTAssertNotNil(
            descendants(of: popoverContent)
                .compactMap { $0 as? NSTextField }
                .first {
                    $0.accessibilityIdentifier()
                        == "manual-haplotype-copy-search"
                }
        )
        model.copyAssignments(from: fixture.samples[1])
        flush(host)
        XCTAssertEqual(
            model.draft[.a, .h1]?.label,
            "MHC-A-Alpha",
            "Copy must mutate the same draft rendered by the editor."
        )
        XCTAssertEqual(exportCount, 1)
    }

    func testMountedDetailViewBoundsOneHundredSelectedSampleSummaries()
        throws
    {
        let fixture = GenotypeManualHaplotypeTask10Fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeTask10Accessibility-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let bundleURL = root.appendingPathComponent(
            "fixture.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            fixture.sidecar,
            forBundleAt: bundleURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(
            result: fixture.result(
                workflowMode: .genotypeOnly,
                bundleURL: bundleURL
            )
        )

        controller.testingSelectMatrixColumns(samples: fixture.samples)

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertEqual(
            rows.filter { $0.0.hasSuffix("Haplotype Completeness") }.count,
            GenotypeManualHaplotypeMultiSamplePresentation
                .maximumVisibleSamples
        )
        XCTAssertTrue(
            rows.contains {
                $0 == ("Additional Selected Samples", "88")
            }
        )
        XCTAssertTrue(
            controller.testingDetailText.contains(
                "88 additional selected samples are not shown."
            )
        )
        XCTAssertNil(controller.testingManualHaplotypeEditorSample)
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private func flush(_ view: NSView) {
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private func waitForWindow(
        excluding existingWindows: Set<ObjectIdentifier>
    ) -> NSWindow? {
        let deadline = Date(timeIntervalSinceNow: 1)
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            if let window = NSApp.windows.first(where: {
                !existingWindows.contains(ObjectIdentifier($0))
                    && $0.isVisible
            }) {
                window.contentView?.layoutSubtreeIfNeeded()
                return window
            }
        } while Date() < deadline
        return nil
    }

}

private extension NSButton {
    func keyDown(
        withCharacters characters: String,
        keyCode: UInt16,
        in window: NSWindow
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Could not construct keyboard event")
            return
        }
        keyDown(with: event)
    }
}
