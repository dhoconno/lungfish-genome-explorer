import Foundation
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCProvenanceStepTests: XCTestCase {
    func testInProcessTransformationProvenanceStepRetainsOptionsAndRuntimeIdentity() {
        let runtimeIdentity = ProvenanceRuntimeIdentity.fixture(
            executablePath: "/Applications/Lungfish.app/Contents/MacOS/Lungfish",
            condaEnvironment: nil
        )
        let transformation = FullLengthONTMHCInProcessTransformationRecord(
            workflowName: "lungfish-in-process:render-candidates",
            workflowVersion: "2026.07",
            argv: ["lungfish-in-process", "render-candidates", "candidate.json"],
            resolvedOptions: ["recordCount": "7"],
            runtimeIdentity: runtimeIdentity,
            inputs: [],
            outputs: [],
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            completedAt: Date(timeIntervalSince1970: 21),
            wallTime: 1
        )

        let step = transformation.provenanceStep()

        XCTAssertEqual(step.resolvedOptions["recordCount"], .string("7"))
        XCTAssertEqual(step.runtimeIdentity, runtimeIdentity)
    }
}
