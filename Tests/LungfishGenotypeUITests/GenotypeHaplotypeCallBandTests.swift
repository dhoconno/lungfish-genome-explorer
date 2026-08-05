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

        XCTAssertEqual(
            after.renderedLocusValue(
                sample: "SAMPLE_001",
                locus: "Very-Long-MHC-A-Locus"
            ),
            "A-override • —"
        )
        XCTAssertFalse(after.renderedValues(sample: "SAMPLE_001").joined().contains("pipeline"))
        XCTAssertTrue(after.accessibilitySummary(sample: "SAMPLE_001").contains("pipeline"))
    }

    func testCompactRowsDescribeResolvedMissingAndAmbiguousCalls() {
        XCTAssertEqual(
            compactSnapshot(h1: "M2A", h2: "M4A").renderedLocusValue(
                sample: "S", locus: "MHC-A"
            ),
            "M2A • M4A"
        )
        XCTAssertEqual(
            compactSnapshot(
                h1: "M2A",
                h2: "-",
                h2Status: .called
            ).renderedLocusValue(sample: "S", locus: "MHC-A"),
            "M2A • —"
        )
        XCTAssertEqual(
            compactSnapshot(
                h1: "ERR: NO HAP",
                h2: "ERR: NO HAP",
                h1Status: .noHaplotype,
                h2Status: .noHaplotype
            ).renderedLocusValue(sample: "S", locus: "MHC-A"),
            "—"
        )
        XCTAssertEqual(
            compactSnapshot(
                h1: "ERR: TMG",
                h2: "ERR: TMG",
                h1Status: .tooManyGenotypes,
                h2Status: .tooManyGenotypes
            ).renderedLocusValue(sample: "S", locus: "MHC-A"),
            "Too many genotypes"
        )
        XCTAssertEqual(
            compactSnapshot(
                h1: "ERR: TMH (M1A, M2A, M3A)",
                h2: "ERR: TMH (M1A, M2A, M3A)",
                h1Status: .tooManyHaplotypes,
                h2Status: .tooManyHaplotypes
            ).renderedLocusValue(sample: "S", locus: "MHC-A"),
            "Too many haplotypes"
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
            values: ["A • B"],
            sampleTitle: "S",
            retainedReadTitle: nil,
            font: font,
            headerFont: headerFont
        )
        let long = GenotypeManualHaplotypeColumnMeasurement.requiredWidth(
            values: [
                String(repeating: "long-haplotype-name-", count: 8)
                    + " • B",
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
        matrix.testingResetProjectionPerformanceCounters()
        let performanceBeforeValueUpdate =
            matrix.testingProjectionPerformanceSnapshot
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
        let performanceAfterValueUpdate =
            matrix.testingProjectionPerformanceSnapshot
        XCTAssertEqual(
            performanceAfterValueUpdate.baseProjectionBuildCount,
            performanceBeforeValueUpdate.baseProjectionBuildCount
        )
        XCTAssertEqual(
            performanceAfterValueUpdate.derivedProjectionPassCount,
            performanceBeforeValueUpdate.derivedProjectionPassCount
        )
        XCTAssertEqual(performanceAfterValueUpdate.columnRebuildCount, 0)
        XCTAssertEqual(performanceAfterValueUpdate.pinnedFullReloadCount, 0)
        XCTAssertEqual(performanceAfterValueUpdate.sampleFullReloadCount, 0)
        XCTAssertEqual(matrix.testingPartialReloadCount, 0)
    }

    func testEffectiveLocusReorderRefreshesEveryHeaderAccessibilitySummary() throws {
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
        matrix.layoutSubtreeIfNeeded()

        for sample in ["SAMPLE_000", "SAMPLE_001"] {
            let before = matrix.testingColumnAccessibilityLabel(
                sample: sample
            ) ?? ""
            XCTAssertLessThan(
                try XCTUnwrap(before.range(of: "MHC-B H1")).lowerBound,
                try XCTUnwrap(
                    before.range(of: "Very-Long-MHC-A-Locus H1")
                ).lowerBound
            )
        }

        matrix.setHaplotypeBand(
            mode: .effectiveMiSeqCalls,
            snapshot: makeSnapshot(
                orderedLoci: ["Very-Long-MHC-A-Locus", "MHC-B"]
            )
        )

        for sample in ["SAMPLE_000", "SAMPLE_001"] {
            let after = matrix.testingColumnAccessibilityLabel(
                sample: sample
            ) ?? ""
            XCTAssertLessThan(
                try XCTUnwrap(
                    after.range(of: "Very-Long-MHC-A-Locus H1")
                ).lowerBound,
                try XCTUnwrap(after.range(of: "MHC-B H1")).lowerBound
            )
        }
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
        sampleOneH1Source: GenotypeEffectiveHaplotypeValue.Source = .pipeline,
        orderedLoci: [String] = ["MHC-B", "Very-Long-MHC-A-Locus"]
    ) -> GenotypeHaplotypeCallBandSnapshot {
        GenotypeHaplotypeCallBandSnapshot(
            orderedLoci: orderedLoci,
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
                .init(
                    sample: "SAMPLE_000",
                    locus: "Very-Long-MHC-A-Locus",
                    h1: .init(
                        value: "Other-A1",
                        status: .called,
                        source: .pipeline,
                        isEditable: true
                    ),
                    h2: .init(
                        value: "Other-A2",
                        status: .called,
                        source: .pipeline,
                        isEditable: true
                    )
                ),
            ]
        )
    }

    private func compactSnapshot(
        h1: String,
        h2: String,
        h1Status: GenotypeHaplotypeCallStatus = .called,
        h2Status: GenotypeHaplotypeCallStatus = .called
    ) -> GenotypeHaplotypeCallBandSnapshot {
        GenotypeHaplotypeCallBandSnapshot(
            orderedLoci: ["MHC-A"],
            calls: [
                .init(
                    sample: "S",
                    locus: "MHC-A",
                    h1: .init(
                        value: h1,
                        status: h1Status,
                        source: .pipeline,
                        isEditable: true
                    ),
                    h2: .init(
                        value: h2,
                        status: h2Status,
                        source: .pipeline,
                        isEditable: true
                    )
                ),
            ]
        )
    }
}
