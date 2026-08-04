import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeHaplotypeCallBandTests: XCTestCase {
    func testSnapshotKeepsDynamicLocusOrderAndSeparateSlotSemantics() throws {
        let before = makeSnapshot(
            sampleOneH1: "A-pipeline",
            sampleOneH1Source: .pipeline
        )
        let after = makeSnapshot(
            sampleOneH1: "A-override",
            sampleOneH1Source: .analystOverride
        )

        XCTAssertEqual(after.orderedLoci, ["MHC-B", "Very-Long-MHC-A-Locus"])
        XCTAssertEqual(after.disclosureTitle, "Haplotype Calls (2 loci)")
        XCTAssertEqual(
            after.value(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h1
            ),
            .init(
                value: "A-override",
                status: .called,
                source: .analystOverride,
                isEditable: true
            )
        )
        XCTAssertEqual(
            after.value(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h2
            )?.status,
            .noHaplotype
        )
        XCTAssertEqual(after.changedSamples(comparedTo: before), ["SAMPLE_001"])

        let tooltip = try XCTUnwrap(
            after.tooltip(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h1
            )
        )
        XCTAssertTrue(tooltip.contains("Very-Long-MHC-A-Locus H1"))
        XCTAssertTrue(tooltip.contains("A-override"))
        XCTAssertTrue(tooltip.contains("status: called"))
        XCTAssertTrue(tooltip.contains("source: analyst override"))

        let accessibility = try XCTUnwrap(
            after.accessibilityLabel(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h2
            )
        )
        XCTAssertTrue(accessibility.contains("SAMPLE_001"))
        XCTAssertTrue(accessibility.contains("H2"))
        XCTAssertTrue(accessibility.contains("no haplotype"))
        XCTAssertTrue(accessibility.contains("pipeline"))

        let rendered = try XCTUnwrap(
            after.renderedValue(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h2
            )
        )
        XCTAssertTrue(rendered.contains("H2"))
        XCTAssertTrue(rendered.contains("no haplotype"))
        XCTAssertTrue(
            rendered.contains("pipeline"),
            "Status and source must remain visible without relying on color."
        )
    }

    func testDynamicGeometryAndLongEffectiveCallsPreserveManualDefaults() {
        let dynamic = GenotypeManualHaplotypeHeaderLayout(
            isEligible: true,
            isExpanded: true,
            ordinaryHeight: 34,
            disclosureHeight: 22,
            rowHeight: 24,
            locusCount: 2
        )
        let legacy = GenotypeManualHaplotypeHeaderLayout(
            isEligible: true,
            isExpanded: true,
            ordinaryHeight: 34,
            disclosureHeight: 22,
            rowHeight: 24
        )

        XCTAssertEqual(dynamic.manualHeight, 70)
        XCTAssertEqual(legacy.manualHeight, 190)

        let font = NSFont.systemFont(ofSize: 13)
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let short = GenotypeManualHaplotypeColumnMeasurement.requiredWidth(
            values: ["H1 A · called · pipeline"],
            sampleTitle: "S",
            retainedReadTitle: nil,
            font: font,
            headerFont: headerFont
        )
        let long = GenotypeManualHaplotypeColumnMeasurement.requiredWidth(
            values: [
                "H1 " + String(repeating: "long-haplotype-name-", count: 8)
                    + " · called · analyst override",
            ],
            sampleTitle: "S",
            retainedReadTitle: nil,
            font: font,
            headerFont: headerFont
        )

        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(
            GenotypeManualHaplotypeValueLayout.drawingAttributes(font: font)[
                .foregroundColor
            ] as? NSColor,
            .labelColor,
            "High-contrast rendering must use the semantic label color."
        )
    }

    func testEffectiveTargetsSupportClickKeyboardAndAccessibilityPress() throws {
        let view = GenotypeManualHaplotypeSampleBandView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 90)
        )
        let snapshot = makeSnapshot()
        let target = GenotypeHaplotypeBandTarget(
            sample: "SAMPLE_001",
            locus: "MHC-B",
            slot: .h1
        )
        view.setHaplotypeBand(mode: .effectiveMiSeqCalls, snapshot: snapshot)
        view.columnFrames = [
            "SAMPLE_001": NSRect(x: 0, y: 0, width: 260, height: 90),
        ]
        view.disclosureHeight = 22
        view.rowHeight = 34
        view.isExpanded = true
        var selections: [GenotypeHaplotypeBandTarget] = []
        view.onTargetSelected = { selections.append($0) }
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(view.testingHitTarget(target))

        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertEqual(button.accessibilityLabel(), snapshot.accessibilityLabel(for: target))
        XCTAssertEqual(button.toolTip, snapshot.tooltip(for: target))

        button.performClick(nil)
        XCTAssertEqual(selections, [target])

        let enter = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        button.keyDown(with: enter)
        XCTAssertEqual(selections, [target, target])

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(selections, [target, target, target])
    }

    func testMatrixSeamWorksBeforeAndAfterConfigurationWithTargetedDamage() {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 2)
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 520)
        )
        let before = makeSnapshot()

        matrix.setHaplotypeBand(
            mode: .effectiveMiSeqCalls,
            snapshot: before
        )
        matrix.configure(
            result: fixture.result(workflowMode: .genotypeOnly),
            sidecar: fixture.sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(matrix.testingHaplotypeBandMode, .effectiveMiSeqCalls)
        XCTAssertEqual(
            matrix.testingHaplotypeBandLoci,
            ["MHC-B", "Very-Long-MHC-A-Locus"]
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandDisclosureLabel,
            "Haplotype Calls (2 loci)"
        )
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h1
            )?.value,
            "A-pipeline"
        )
        XCTAssertFalse(
            matrix.testingBuildActualContextMenu(
                for: .column(sample: "SAMPLE_001")
            )?.items.contains { $0.title == "Edit Haplotype Assignments…" }
                ?? true
        )

        let selectedTarget = GenotypeHaplotypeBandTarget(
            sample: "SAMPLE_001",
            locus: "MHC-B",
            slot: .h2
        )
        var selections: [GenotypeHaplotypeBandTarget] = []
        matrix.onHaplotypeBandTargetSelected = { selections.append($0) }
        matrix.testingHaplotypeBandHitTarget(selectedTarget)?.performClick(nil)
        XCTAssertEqual(selections, [selectedTarget])

        matrix.testingResetManualHaplotypeBandInvalidations()
        let after = makeSnapshot(
            sampleOneH1: "A-override",
            sampleOneH1Source: .analystOverride
        )
        matrix.setHaplotypeBand(
            mode: .effectiveMiSeqCalls,
            snapshot: after
        )

        XCTAssertEqual(
            matrix.testingManualHaplotypeBandInvalidatedSamples,
            ["SAMPLE_001"]
        )
        XCTAssertEqual(
            matrix.testingHaplotypeBandValue(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus",
                slot: .h1
            )?.source,
            .analystOverride
        )
    }

    func testEffectiveBandTypographyScalesWithoutChangingDynamicRowCount() {
        let fixture = GenotypeManualHaplotypeTask10Fixture(sampleCount: 2)
        let matrix = GenotypeComparisonMatrixView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 520)
        )
        matrix.configure(result: fixture.result(workflowMode: .haplotyped))
        matrix.setHaplotypeBand(
            mode: .effectiveMiSeqCalls,
            snapshot: makeSnapshot()
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        let baselineRowHeight = matrix.testingManualHaplotypeBandRowHeight
        matrix.testingSetManualHaplotypeBandTypographyScale(1.8)
        matrix.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            matrix.testingManualHaplotypeBandRowHeight,
            baselineRowHeight
        )
        XCTAssertEqual(matrix.testingHaplotypeBandExpandedRowCount, 2)
    }

    private func makeSnapshot(
        sampleOneH1: String = "A-pipeline",
        sampleOneH1Source: GenotypeEffectiveHaplotypeValue.Source = .pipeline
    ) -> GenotypeHaplotypeCallBandSnapshot {
        GenotypeHaplotypeCallBandSnapshot(
            orderedLoci: ["MHC-B", "Very-Long-MHC-A-Locus"],
            calls: [
                .init(
                    sample: "SAMPLE_001",
                    locus: "MHC-B",
                    h1: .init(
                        value: "B1",
                        status: .called,
                        source: .pipeline,
                        isEditable: true
                    ),
                    h2: .init(
                        value: "B2",
                        status: .called,
                        source: .pipeline,
                        isEditable: true
                    )
                ),
                .init(
                    sample: "SAMPLE_001",
                    locus: "Very-Long-MHC-A-Locus",
                    h1: .init(
                        value: sampleOneH1,
                        status: .called,
                        source: sampleOneH1Source,
                        isEditable: true
                    ),
                    h2: .init(
                        value: "ERR: NO HAP",
                        status: .noHaplotype,
                        source: .pipeline,
                        isEditable: false
                    )
                ),
                .init(
                    sample: "SAMPLE_000",
                    locus: "MHC-B",
                    h1: .init(
                        value: "Other-B1",
                        status: .called,
                        source: .pipeline,
                        isEditable: true
                    ),
                    h2: .init(
                        value: "Other-B2",
                        status: .called,
                        source: .pipeline,
                        isEditable: true
                    )
                ),
            ]
        )
    }
}
