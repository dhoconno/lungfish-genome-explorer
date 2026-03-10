import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexPlanTests: XCTestCase {

    // MARK: - DemultiplexStep

    func testDemultiplexStepDefaults() {
        let step = DemultiplexStep(label: "Test", barcodeKitID: "NBD114")
        XCTAssertEqual(step.label, "Test")
        XCTAssertEqual(step.barcodeKitID, "NBD114")
        XCTAssertEqual(step.barcodeLocation, .bothEnds)
        XCTAssertEqual(step.symmetryMode, .symmetric)
        XCTAssertEqual(step.errorRate, 0.15, accuracy: 0.001)
        XCTAssertEqual(step.minimumOverlap, 3)
        XCTAssertTrue(step.searchReverseComplement)
        XCTAssertTrue(step.sampleAssignments.isEmpty)
        XCTAssertEqual(step.ordinal, 0)
    }

    func testDemultiplexStepIdentifiable() {
        let step1 = DemultiplexStep(label: "A", barcodeKitID: "NBD114")
        let step2 = DemultiplexStep(label: "B", barcodeKitID: "NBD114")
        XCTAssertNotEqual(step1.id, step2.id)
    }

    func testDemultiplexStepCodableRoundTrip() throws {
        let step = DemultiplexStep(
            label: "Outer",
            barcodeKitID: "NBD114",
            barcodeLocation: .fivePrime,
            symmetryMode: .asymmetric,
            errorRate: 0.20,
            minimumOverlap: 20,
            searchReverseComplement: false,
            ordinal: 1
        )
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(DemultiplexStep.self, from: data)
        XCTAssertEqual(decoded.label, "Outer")
        XCTAssertEqual(decoded.barcodeKitID, "NBD114")
        XCTAssertEqual(decoded.barcodeLocation, .fivePrime)
        XCTAssertEqual(decoded.symmetryMode, .asymmetric)
        XCTAssertEqual(decoded.errorRate, 0.20, accuracy: 0.001)
        XCTAssertEqual(decoded.minimumOverlap, 20)
        XCTAssertFalse(decoded.searchReverseComplement)
        XCTAssertEqual(decoded.ordinal, 1)
    }

    // MARK: - DemultiplexPlan

    func testDemultiplexPlanIsSingleStep() {
        let empty = DemultiplexPlan()
        XCTAssertTrue(empty.isSingleStep)

        let single = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114"),
        ])
        XCTAssertTrue(single.isSingleStep)

        let multi = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114", ordinal: 0),
            DemultiplexStep(label: "Step 1", barcodeKitID: "RBK114", ordinal: 1),
        ])
        XCTAssertFalse(multi.isSingleStep)
    }

    func testDemultiplexPlanValidateEmptyThrows() {
        let plan = DemultiplexPlan()
        XCTAssertThrowsError(try plan.validate()) { error in
            guard case DemultiplexPlanError.noSteps = error else {
                XCTFail("Expected noSteps error, got \(error)")
                return
            }
        }
    }

    func testDemultiplexPlanValidateMissingKitThrows() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Bad Step", barcodeKitID: ""),
        ])
        XCTAssertThrowsError(try plan.validate()) { error in
            if case .missingKit(let step) = error as? DemultiplexPlanError {
                XCTAssertEqual(step, "Bad Step")
            } else {
                XCTFail("Expected missingKit error")
            }
        }
    }

    func testDemultiplexPlanValidateSucceeds() {
        let plan = DemultiplexPlan(steps: [
            DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114"),
        ])
        XCTAssertNoThrow(try plan.validate())
    }

    func testDemultiplexPlanCompositeSampleNames() {
        let plan = DemultiplexPlan(
            steps: [DemultiplexStep(label: "Step 0", barcodeKitID: "NBD114")],
            compositeSampleNames: ["BC01/bc1003--bc1016": "Patient-042"]
        )
        XCTAssertEqual(plan.compositeSampleNames["BC01/bc1003--bc1016"], "Patient-042")
    }

    func testDemultiplexPlanCodableRoundTrip() throws {
        let plan = DemultiplexPlan(
            steps: [
                DemultiplexStep(label: "Outer", barcodeKitID: "NBD114", ordinal: 0),
                DemultiplexStep(label: "Inner", barcodeKitID: "RBK114", ordinal: 1),
            ],
            compositeSampleNames: ["BC01/BC02": "Sample-A"]
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(DemultiplexPlan.self, from: data)
        XCTAssertEqual(decoded.steps.count, 2)
        XCTAssertEqual(decoded.steps[0].label, "Outer")
        XCTAssertEqual(decoded.steps[1].label, "Inner")
        XCTAssertEqual(decoded.compositeSampleNames["BC01/BC02"], "Sample-A")
    }

    // MARK: - DemultiplexPlanError

    func testDemultiplexPlanErrorDescriptions() {
        XCTAssertNotNil(DemultiplexPlanError.noSteps.errorDescription)
        XCTAssertNotNil(DemultiplexPlanError.missingKit(step: "Test").errorDescription)
        XCTAssertTrue(
            DemultiplexPlanError.missingKit(step: "Outer").errorDescription?.contains("Outer") == true
        )
    }

    func testDemultiplexPlanErrorIsLocalizedError() {
        let error: Error = DemultiplexPlanError.noSteps
        XCTAssertNotNil(error.localizedDescription)
    }

    // MARK: - DemultiplexError

    func testDemultiplexErrorNoOutputResults() {
        let error = DemultiplexError.noOutputResults
        XCTAssertNotNil(error.errorDescription)
    }

    func testDemultiplexErrorBundleCreationFailed() {
        let error = DemultiplexError.bundleCreationFailed(barcode: "BC01", underlying: "disk full")
        XCTAssertTrue(error.errorDescription?.contains("BC01") == true)
        XCTAssertTrue(error.errorDescription?.contains("disk full") == true)
    }
}
