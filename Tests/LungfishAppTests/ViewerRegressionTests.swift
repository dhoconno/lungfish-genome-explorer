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
}
