import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class ViewerRegressionTests: XCTestCase {

    func testOperationPreviewHidesFASTAPreviewForNonPreviewOperations() {
        let view = OperationPreviewView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))

        view.setFASTAContent(">read1\nACGT\n")
        XCTAssertTrue(view.testShowsFASTAPreview)

        view.update(operation: .qualityTrim, statistics: nil)

        XCTAssertFalse(view.testShowsFASTAPreview)
    }

    func testFASTQMetadataDrawerPreservesMultiStepDemultiplexPlans() throws {
        let drawer = FASTQMetadataDrawerView()
        let plan = DemultiplexPlan(
            steps: [
                DemultiplexStep(label: "Outer", barcodeKitID: "NBD114", ordinal: 0),
                DemultiplexStep(label: "Inner", barcodeKitID: "RBK114", ordinal: 1),
            ],
            compositeSampleNames: ["outer+inner": "sample-1"]
        )
        let planJSON = try XCTUnwrap(String(data: JSONEncoder().encode(plan), encoding: .utf8))
        let metadata = FASTQDemultiplexMetadata(demuxPlanJSON: planJSON)

        drawer.configure(fastqURL: nil, metadata: metadata)
        let roundTrip = drawer.currentDemuxPlan()

        XCTAssertEqual(roundTrip.steps.count, 2)
        XCTAssertEqual(roundTrip.steps.map(\.label), ["Outer", "Inner"])
        XCTAssertEqual(roundTrip.steps.map(\.barcodeKitID), ["NBD114", "RBK114"])
        XCTAssertEqual(roundTrip.steps.map(\.ordinal), [0, 1])
        XCTAssertEqual(roundTrip.compositeSampleNames, plan.compositeSampleNames)
    }

    func testFASTQMetadataDrawerDividerExposesStableAccessibilityIdentifier() {
        let drawer = FASTQMetadataDrawerView()

        XCTAssertEqual(drawer.testDrawerDivider.accessibilityIdentifier(), "fastq-metadata-drawer-divider")
        XCTAssertEqual(drawer.testDrawerDivider.accessibilityLabel(), "FASTQ metadata drawer resize handle")
    }

    func testHorizontalPanAmountUsesExplicitScrollDirectionPreference() {
        let traditional = SequenceViewerView.horizontalPanAmountForTesting(
            deltaX: 12,
            scale: 3,
            hasPreciseScrollingDeltas: true,
            preference: .traditional,
            isDirectionInvertedFromDevice: true
        )
        let natural = SequenceViewerView.horizontalPanAmountForTesting(
            deltaX: 12,
            scale: 3,
            hasPreciseScrollingDeltas: true,
            preference: .natural,
            isDirectionInvertedFromDevice: true
        )

        XCTAssertEqual(traditional, 36, accuracy: 0.001)
        XCTAssertEqual(natural, -36, accuracy: 0.001)
    }

    func testSystemHorizontalPanAmountFollowsSystemScrollDirection() {
        let systemTraditional = SequenceViewerView.horizontalPanAmountForTesting(
            deltaX: 12,
            scale: 3,
            hasPreciseScrollingDeltas: true,
            preference: .system,
            isDirectionInvertedFromDevice: false
        )
        let systemNatural = SequenceViewerView.horizontalPanAmountForTesting(
            deltaX: 12,
            scale: 3,
            hasPreciseScrollingDeltas: true,
            preference: .system,
            isDirectionInvertedFromDevice: true
        )

        XCTAssertEqual(systemTraditional, 36, accuracy: 0.001)
        XCTAssertEqual(systemNatural, -36, accuracy: 0.001)
    }

    func testBundleScrollDirectionOverrideFlipsNaturalAndTraditionalLabels() {
        XCTAssertEqual(
            SequenceViewerView.effectiveHorizontalScrollDirectionForTesting(
                bundleOverride: .traditional,
                globalPreference: .natural
            ),
            .natural
        )
        XCTAssertEqual(
            SequenceViewerView.effectiveHorizontalScrollDirectionForTesting(
                bundleOverride: .natural,
                globalPreference: .traditional
            ),
            .traditional
        )
    }

    func testBundleScrollDirectionOverrideStillAllowsSystemAndGlobalFallback() {
        XCTAssertEqual(
            SequenceViewerView.effectiveHorizontalScrollDirectionForTesting(
                bundleOverride: .system,
                globalPreference: .traditional
            ),
            .system
        )
        XCTAssertEqual(
            SequenceViewerView.effectiveHorizontalScrollDirectionForTesting(
                bundleOverride: nil,
                globalPreference: .natural
            ),
            .natural
        )
    }

    func testPinchMagnificationFactorMapsDirectionAndClampsExtremes() {
        XCTAssertGreaterThan(SequenceViewerView.pinchZoomFactorForTesting(magnification: 0.12), 1.0)
        XCTAssertLessThan(SequenceViewerView.pinchZoomFactorForTesting(magnification: -0.12), 1.0)
        XCTAssertEqual(SequenceViewerView.pinchZoomFactorForTesting(magnification: 0), 1.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(SequenceViewerView.pinchZoomFactorForTesting(magnification: 10), 8.0)
        XCTAssertGreaterThanOrEqual(SequenceViewerView.pinchZoomFactorForTesting(magnification: -10), 0.125)
    }

    func testReferenceFramePinchZoomKeepsAnchorPositionStable() {
        let frame = ReferenceFrame(
            chromosome: "chr1",
            start: 1_000,
            end: 9_000,
            pixelWidth: 1_000,
            sequenceLength: 20_000
        )
        frame.trailingInset = ReferenceFrame.defaultTrailingInset
        let anchorX: CGFloat = 250
        let anchoredPosition = frame.genomicPosition(for: anchorX)

        frame.zoom(by: 2.0, anchorScreenX: anchorX)

        XCTAssertEqual(frame.genomicPosition(for: anchorX), anchoredPosition, accuracy: 0.5)
        XCTAssertEqual(frame.end - frame.start, 4_000, accuracy: 0.5)
    }

    func testBundleAnnotationDisplayKeepsSubpixelFeaturesInSquishedModeAtNarrowWidths() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let frame = ReferenceFrame(
            chromosome: "chr1",
            start: 0,
            end: 5_700_000,
            pixelWidth: 800,
            sequenceLength: 5_700_000
        )
        frame.trailingInset = ReferenceFrame.defaultTrailingInset
        let annotations = [
            SequenceAnnotation(
                type: .gene,
                name: "early-small",
                chromosome: "chr1",
                start: 100_000,
                end: 100_900
            ),
            SequenceAnnotation(
                type: .gene,
                name: "late-small",
                chromosome: "chr1",
                start: 2_000_000,
                end: 2_000_900
            ),
        ]

        XCTAssertGreaterThan(frame.scale, AppSettings.shared.squishedThresholdBpPerPixel)
        XCTAssertLessThan(frame.scale, AppSettings.shared.densityThresholdBpPerPixel)
        XCTAssertEqual(
            viewer.debugBundleDisplayAnnotationNames(annotations, frame: frame),
            ["early-small", "late-small"]
        )
    }
}
