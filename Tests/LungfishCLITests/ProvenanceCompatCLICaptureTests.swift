import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Captures, once, the run-bearing envelope that `CLIProvenanceSupport.recordSingleStepRun`
/// writes for a cancelled run whose last step exited 0. It runs only with
/// `LUNGFISH_CAPTURE_PROVENANCE_COMPAT=1`, inside a temporary `.lungfish` project, and
/// refuses to overwrite an existing case. The gate never sets the variable, so the test is
/// skipped there.
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

        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-compat-capture")
        defer { TestTempDirectory.cleanup(temporaryRoot) }
        let project = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysis = project.appendingPathComponent("Analyses/fastq-trim-cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Inputs", isDirectory: true),
            withIntermediateDirectories: true
        )

        let input = project.appendingPathComponent("Inputs/reads.fastq")
        let output = analysis.appendingPathComponent("trimmed.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
        try Data().write(to: output)

        let envelope = try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq trim",
            parameters: ["minQuality": .integer(20), "limit": .integer(10)],
            defaults: ["threads": .integer(4)],
            toolName: "fastp",
            toolVersion: "0.24.0",
            command: [CLICommandIdentity.executableName, "fastq", "trim", input.path, "--output", output.path],
            inputs: [ProvenanceRecorder.fileRecord(url: input, format: .fastq, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: output, format: .fastq, role: .output)],
            exitCode: 0,
            wallTime: 0.25,
            peakMemoryBytes: 42_000_000,
            stderr: "cancelled by user",
            status: .cancelled,
            outputDirectory: analysis,
            writeFileSidecars: false
        )
        XCTAssertEqual(envelope.legacyWorkflowRun().status, .cancelled)
        XCTAssertEqual(envelope.exitStatus, 0)

        let sidecar = analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: sidecar).path)
        )
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s1-cancelled-single-step",
            layoutPath: "Analyses/fastq-trim-cancelled/.lungfish-provenance.json",
            shape: "S1",
            family: "F01",
            origin: "Captured once at 81e89a306 in a temporary .lungfish project by ProvenanceCompatCLICaptureTests. CLIProvenanceSupport.recordSingleStepRun for a run with status cancelled whose only step exited 0, with a peak memory figure. The envelope embeds the run as legacyWorkflowRun, and the word cancelled appears only there and in the top-level status key. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: try Data(contentsOf: sidecar)
        )
    }
}
