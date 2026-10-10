import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Runs the cancelled single-step scenario again and checks that its facts equal the facts of
/// the frozen case s1-cancelled-single-step, ignoring what a run decides for itself (the host
/// values under `recorded` and the run's own wall time). A lane that changes
/// `CLIProvenanceSupport.recordSingleStepRun` runs the same scenario and relies on this check to
/// prove its new bytes still say what the frozen ones said.
final class ProvenanceCompatCLIScenarioTests: XCTestCase {
    func testCancelledSingleStepScenarioReproducesItsCase() async throws {
        try XCTSkipIf(
            ProvenanceSigningConfiguration.defaultProvider() != nil,
            "A provenance signing key is set, so the writer would sign the record"
        )
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }

        let sidecar = try await ProvenanceCompatCLIScenarios.cancelledSingleStepRun(in: project)

        let live = try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: project.root)
        let frozen = try ProvenanceCompatFacts.decode(
            try XCTUnwrap(ProvenanceCompatCorpus.expectedFactsData(for: "s1-cancelled-single-step"))
        )
        let differences = live.differences(from: frozen, ignoring: ProvenanceCompatFacts.runSpecific)
        XCTAssertTrue(differences.isEmpty, "scenario drifted from its case: \(differences)")
        XCTAssertEqual(live.status, "cancelled")
        XCTAssertEqual(live.exitStatus, 0)
    }
}
