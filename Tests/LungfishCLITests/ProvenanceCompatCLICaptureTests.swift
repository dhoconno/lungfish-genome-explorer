import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Captures, once, the run-bearing envelope that `CLIProvenanceSupport.recordSingleStepRun`
/// writes for a cancelled run whose last step exited 0. It runs only with
/// `LUNGFISH_CAPTURE_PROVENANCE_COMPAT=1`, inside a temporary `.lungfish` project, and
/// refuses to overwrite an existing case. The gate never sets the variable, so the test is
/// skipped there. The run itself is `ProvenanceCompatCLIScenarios.cancelledSingleStepRun`,
/// which a later lane calls again to run the same writer after it changes it.
///
/// Today the word `cancelled` lives only in the embedded `legacyWorkflowRun`. A later lane
/// that drops the embedded run must keep the status readable, and this case is the proof.
final class ProvenanceCompatCLICaptureTests: XCTestCase {
    func testCapturesCancelledSingleStepRun() async throws {
        try XCTSkipUnless(
            ProvenanceCompatCorpus.captureCasesRequested,
            "Set \(ProvenanceCompatCorpus.captureCasesVariable)=1 to capture a new corpus case"
        )
        try XCTSkipIf(
            ProvenanceSigningConfiguration.defaultProvider() != nil,
            "A provenance signing key is set, so the writer would sign the capture"
        )

        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }

        let sidecar = try await ProvenanceCompatCLIScenarios.cancelledSingleStepRun(in: project)

        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(envelope.legacyWorkflowRun().status, .cancelled)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: sidecar).path)
        )
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s1-cancelled-single-step",
            layoutPath: "\(ProvenanceCompatCLIScenarios.cancelledSingleStepAnalysisFolder)/.lungfish-provenance.json",
            shape: "S1",
            family: "F01",
            origin: "Captured once at 81e89a306 in a temporary .lungfish project by ProvenanceCompatCLICaptureTests. CLIProvenanceSupport.recordSingleStepRun for a run with status cancelled whose only step exited 0, with a peak memory figure. The envelope embeds the run as legacyWorkflowRun, and the word cancelled appears only there and in the top-level status key. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: try Data(contentsOf: sidecar)
        )
    }
}
