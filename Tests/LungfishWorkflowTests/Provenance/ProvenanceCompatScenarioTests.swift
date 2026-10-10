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

        // The GATK writer may write either shape. Today it writes a bare run with
        // `WorkflowRun.writeSidecar`, and a lane may move it to a run-bearing envelope. So this
        // comparison also forgives what that conversion changes by design, which is the decoder,
        // strict acceptance, the embedded run's status, repeated files and the container keys of
        // each step's own bytes. It leaves both legacy step views compared exactly, because that is
        // where a per-step container image or digest that a writer loses or changes still shows.
        let ignored = ProvenanceCompatFacts.runSpecific
            .union(ProvenanceCompatFacts.shapeChange)
            .union([.stepRecordedContainer])
        let (live, frozen) = try Self.liveAndFrozenFacts(of: sidecar, in: project, forCase: "s3-gatk-container-bare-run")
        let differences = live.differences(from: frozen, ignoring: ignored)
        #expect(differences.isEmpty, "scenario for s3-gatk-container-bare-run drifted: \(differences)")

        // A container that one step loses or changes in either legacy view still fails.
        try #require(live.legacyRunSteps.count == 2 && live.canonicalRunSteps.count == 2)
        #expect(ignored.isDisjoint(with: [.legacyRunSteps, .canonicalRunSteps]))
        var lostDigest = live
        lostDigest.legacyRunSteps[1].containerDigest = nil
        #expect(lostDigest.differences(from: frozen, ignoring: ignored).count == 1)
        var changedImage = live
        changedImage.canonicalRunSteps[0].containerImage = "registry.example/other:1"
        #expect(changedImage.differences(from: frozen, ignoring: ignored).count == 1)
    }

    // MARK: Helpers

    /// Compares the facts of `sidecar` with the frozen case's expected facts, without the run-specific fields.
    private static func expectFacts(of sidecar: URL, in project: ProvenanceCompatScenarios.Project, equalToCase id: String) throws {
        let (live, frozen) = try liveAndFrozenFacts(of: sidecar, in: project, forCase: id)
        let differences = live.differences(from: frozen, ignoring: ProvenanceCompatFacts.runSpecific)
        #expect(differences.isEmpty, "scenario for \(id) drifted: \(differences)")
    }

    /// The facts of `sidecar` as the readers say them now, and the frozen case's expected facts.
    private static func liveAndFrozenFacts(
        of sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        forCase id: String
    ) throws -> (live: ProvenanceCompatFacts, frozen: ProvenanceCompatFacts) {
        let live = try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: project.root)
        let frozen = try ProvenanceCompatFacts.decode(
            try #require(ProvenanceCompatCorpus.expectedFactsData(for: id), "case \(id) has no expected facts")
        )
        return (live, frozen)
    }
}
