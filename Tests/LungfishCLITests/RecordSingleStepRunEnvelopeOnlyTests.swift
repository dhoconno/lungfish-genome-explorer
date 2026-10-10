import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// `CLIProvenanceSupport.recordSingleStepRun` used to nest a run under `legacyWorkflowRun`,
/// and the word `cancelled` lived only there and in the top-level `status` key. The encoder no
/// longer writes the nested run (finding R8, lane W2A), so the status key and the envelope's own
/// fields must carry everything the nested run carried for a cancelled run whose only step
/// exited 0. This runs the scenario behind the frozen case s1-cancelled-single-step again.
final class RecordSingleStepRunEnvelopeOnlyTests: XCTestCase {
    func testAFreshSingleStepRecordHoldsNoNestedRunAndReadsBackCancelled() async throws {
        try XCTSkipIf(
            ProvenanceSigningConfiguration.defaultProvider() != nil,
            "A provenance signing key is set, so the writer would sign the record"
        )
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }

        let sidecar = try await ProvenanceCompatCLIScenarios.cancelledSingleStepRun(in: project)

        let bytes = try Data(contentsOf: sidecar)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["legacyWorkflowRun"], "the record holds no nested run")
        XCTAssertEqual(object["status"] as? String, "cancelled")
        XCTAssertEqual(object["exitStatus"] as? Int, 0, "the only step exited 0, so the exit status cannot say cancelled")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertNil(envelope.legacyRun)
        XCTAssertEqual(envelope.status, .cancelled)
        let rebuilt = envelope.legacyWorkflowRun()
        XCTAssertEqual(rebuilt.status, .cancelled)
        XCTAssertEqual(rebuilt.steps.first?.peakMemoryBytes, 42_000_000)
        XCTAssertEqual(rebuilt.steps.first?.exitCode, 0)
        XCTAssertEqual(rebuilt.parameters["minQuality"], .integer(20))
        XCTAssertEqual(rebuilt.parameters["limit"], .integer(10))

        // The compat keys stay, so an older reader that decodes a WorkflowRun still can.
        let legacy = try ProvenanceJSON.decoder.decode(WorkflowRun.self, from: bytes)
        XCTAssertEqual(legacy.status, .cancelled)
    }
}
