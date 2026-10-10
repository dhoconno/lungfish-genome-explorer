import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Captures, once, the sidecar shapes that today's writers produce and that later Phase 2.4
/// lanes stop writing. It runs only with `LUNGFISH_CAPTURE_PROVENANCE_COMPAT=1`, inside a
/// temporary `.lungfish` project, and refuses to overwrite an existing case. The gate never
/// sets the variable, so these tests are skipped there.
///
/// Every run comes from `ProvenanceCompatScenarios`, which later lanes call again to run the
/// same writer after they change it (see ProvenanceCompatScenarioTests). The single-step helper
/// that lives in the CLI is captured by ProvenanceCompatCLICaptureTests.
@Suite("Provenance compatibility shape capture", .serialized)
struct ProvenanceCompatShapeCaptureTests {
    static let baseCommit = "81e89a306"

    // MARK: Recorder run with a readSetPlan parameter

    @Test(
        "captures a ProvenanceRecorder run whose parameters hold a readSetPlan",
        .enabled(if: ProvenanceCompatCorpus.captureCasesRequested)
    )
    func capturesRecorderRunWithReadSetPlan() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }

        let sidecar = try await ProvenanceCompatScenarios.recorderRunWithReadSetPlan(in: project)

        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s1-recorder-readsetplan",
            layoutPath: "\(ProvenanceCompatScenarios.recorderAnalysisFolder)/.lungfish-provenance.json",
            shape: "S1",
            family: "F01",
            origin: "Captured once at \(Self.baseCommit) in a temporary .lungfish project by ProvenanceCompatShapeCaptureTests. ProvenanceRecorder.beginRun with parameters that include a readSetPlan, two recordStep calls (kraken2 and bracken), completeRun, then save with explicit options that do not name the readSetPlan. The embedded legacyWorkflowRun is the only place the plan survives. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: try Data(contentsOf: sidecar)
        )
    }

    // MARK: WorkflowRun written both ways

    @Test(
        "captures a WorkflowRun written through canonicalEnvelope and ProvenanceWriter",
        .enabled(if: ProvenanceCompatCorpus.captureCasesRequested)
    )
    func capturesCanonicalEnvelopeWriterRun() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)
        let run = try ProvenanceCompatScenarios.variantsPhaseRun(project: project.root, analysis: analysis)

        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: analysis)

        let bytes = try Data(contentsOf: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s1-canonical-envelope-run",
            layoutPath: "\(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)/.lungfish-provenance.json",
            shape: "S1",
            family: "F01",
            origin: "Captured once at \(Self.baseCommit) in a temporary .lungfish project by ProvenanceCompatShapeCaptureTests. The same WorkflowRun as case s3-write-sidecar-bare-run, converted with WorkflowRun.canonicalEnvelope() and written through ProvenanceWriter(signingProvider: nil), which is the shape the bare-run writers move to. The envelope embeds the run as legacyWorkflowRun. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: bytes
        )
    }

    @Test(
        "captures a bare WorkflowRun written by WorkflowRun.writeSidecar",
        .enabled(if: ProvenanceCompatCorpus.captureCasesRequested)
    )
    func capturesBareRunWrittenBySidecarWriter() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)
        let run = try ProvenanceCompatScenarios.variantsPhaseRun(project: project.root, analysis: analysis)

        try run.writeSidecar(to: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        let bytes = try Data(contentsOf: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s3-write-sidecar-bare-run",
            layoutPath: "\(ProvenanceCompatScenarios.variantsPhaseAnalysisFolder)/.lungfish-provenance.json",
            shape: "S3",
            family: "F01",
            origin: "Captured once at \(Self.baseCommit) in a temporary .lungfish project by ProvenanceCompatShapeCaptureTests. A WorkflowRun modeled on the variants phase command plan, written by WorkflowRun.writeSidecar, the writer ten call sites use today. Inside the project the writer rewrote the project, tool root and storage root paths. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: bytes
        )
    }

    // MARK: Bare run with a container on every step

    @Test(
        "captures a bare run whose steps each carry a container image and digest",
        .enabled(if: ProvenanceCompatCorpus.captureCasesRequested)
    )
    func capturesBareRunWithContainerOnEveryStep() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }

        let sidecar = try await ProvenanceCompatScenarios.gatkContainerRun(in: project)

        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s3-gatk-container-bare-run",
            layoutPath: "\(ProvenanceCompatScenarios.gatkContainerAnalysisFolder)/.lungfish-provenance.json",
            shape: "S3",
            family: "F01",
            origin: "Captured once at \(Self.baseCommit) in a temporary .lungfish project by ProvenanceCompatShapeCaptureTests. The real GATKPipelineExecutor ran a joint genotyping request (CombineGVCFs, then GenotypeGVCFs) with an injected runner and wrote the record with WorkflowRun.writeSidecar, the way the GATK writer does today. Both steps carry containerImage and containerDigest, and neither has a runtime identity of its own. The image reference is real in form, and the digest is the SHA-256 of that reference. Bytes are exactly what the executor produced, no edit. The recorded app version and host name the test host that ran the capture.",
            bytes: try Data(contentsOf: sidecar)
        )
    }
}
