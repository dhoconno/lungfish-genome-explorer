import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishWorkflow

/// Runs each reusable scenario again and checks that its facts equal the facts of the frozen
/// case it was captured as, ignoring what a run decides for itself (the host values under
/// `recorded` and the run's own wall time). If a scenario drifted from its capture, or a
/// writer changed what it records, this suite fails. A lane that changes a writer runs the same
/// scenario and relies on this check to prove its new bytes still say what the frozen ones said.
@Suite("Provenance compatibility scenarios")
struct ProvenanceCompatScenarioTests {
    @Test("the recorder scenario reproduces case s1-recorder-readsetplan")
    func recorderScenarioReproducesItsCase() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sidecar = try await ProvenanceCompatScenarios.recorderRunWithReadSetPlan(in: project)
        try Self.expectFacts(of: sidecar, in: project, equalToCase: "s1-recorder-readsetplan")
    }

    @Test("the variants phase scenario written as a canonical envelope reproduces case s1-canonical-envelope-run")
    func variantsPhaseAsCanonicalEnvelopeReproducesItsCase() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)
        let run = try ProvenanceCompatScenarios.variantsPhaseRun(project: project.root, analysis: analysis)
        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: analysis)
        try Self.expectFacts(
            of: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            equalToCase: "s1-canonical-envelope-run"
        )
    }

    @Test("the variants phase scenario written by writeSidecar reproduces case s3-write-sidecar-bare-run")
    func variantsPhaseAsBareRunReproducesItsCase() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)
        let run = try ProvenanceCompatScenarios.variantsPhaseRun(project: project.root, analysis: analysis)
        let sidecar = analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try run.writeSidecar(to: sidecar)
        try Self.expectFacts(of: sidecar, in: project, equalToCase: "s3-write-sidecar-bare-run")
    }

    @Test("the GATK container scenario reproduces case s3-gatk-container-bare-run")
    func gatkContainerScenarioReproducesItsCase() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sidecar = try await ProvenanceCompatScenarios.gatkContainerRun(in: project)
        try Self.expectFacts(of: sidecar, in: project, equalToCase: "s3-gatk-container-bare-run")
    }

    // MARK: Helpers

    /// Compares the facts of `sidecar` with the frozen case's expected facts, without the run-specific fields.
    private static func expectFacts(of sidecar: URL, in project: ProvenanceCompatScenarios.Project, equalToCase id: String) throws {
        let live = try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: project.root)
        let frozen = try ProvenanceCompatFacts.decode(
            try #require(ProvenanceCompatCorpus.expectedFactsData(for: id), "case \(id) has no expected facts")
        )
        let differences = live.differences(from: frozen, ignoring: ProvenanceCompatFacts.runSpecific)
        #expect(differences.isEmpty, "scenario for \(id) drifted: \(differences)")
    }
}
