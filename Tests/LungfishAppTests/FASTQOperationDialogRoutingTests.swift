import XCTest
@testable import LungfishApp

@MainActor
final class FASTQOperationDialogRoutingTests: XCTestCase {
    func testClassificationToolsUseFixedBatchOutputModeAndHideOutputStrategyPicker() {
        let state = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        for toolID in [FASTQOperationToolID.kraken2, .esViritu, .taxTriage] {
            state.selectTool(toolID)

            XCTAssertEqual(state.outputMode, .fixedBatch, "\(toolID.rawValue) should force fixedBatch output mode")
            XCTAssertFalse(state.showsOutputStrategyPicker, "\(toolID.rawValue) should hide the output strategy picker")
            state.outputMode = .perInput
            XCTAssertEqual(state.outputMode, .fixedBatch, "\(toolID.rawValue) should clamp outputMode back to fixedBatch")
            XCTAssertFalse(state.showsOutputStrategyPicker, "\(toolID.rawValue) should keep the output strategy picker hidden")
        }
    }

    func testMappingDefaultsToPerInputOutputModeAndRequiresReferenceSelection() {
        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.minimap2)

        XCTAssertEqual(state.outputMode, .perInput)
        XCTAssertTrue(state.showsOutputStrategyPicker)
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.requiredInputKinds.contains(.referenceSequence))
    }

    func testAssemblyCategorySeedsSpadesAsDefaultTool() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        XCTAssertEqual(state.selectedToolID, .spades)
        XCTAssertEqual(state.outputMode, .perInput)
        XCTAssertTrue(state.isRunEnabled)
    }

    func testDatasetLabelSummarizesMultipleSelectedInputs() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [
                URL(fileURLWithPath: "/tmp/sample-1.fastq"),
                URL(fileURLWithPath: "/tmp/sample-2.fastq"),
                URL(fileURLWithPath: "/tmp/sample-3.fastq"),
            ]
        )

        XCTAssertEqual(state.datasetLabel, "3 FASTQ datasets")
    }
}
