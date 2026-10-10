import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// The writer runs behind captured corpus cases that need LungfishCLI. The rest are in
/// `ProvenanceCompatScenarios` (LungfishTestSupport), which cannot import the CLI.
enum ProvenanceCompatCLIScenarios {
    enum ScenarioError: Error, CustomStringConvertible {
        case signingKeyIsSet

        var description: String {
            "A provenance signing key is set in the environment, so the writer would sign the record. Unset it to run the scenario."
        }
    }

    /// The folder, relative to the project, that the cancelled single-step scenario writes into.
    static let cancelledSingleStepAnalysisFolder = "Analyses/fastq-trim-cancelled"

    /// `CLIProvenanceSupport.recordSingleStepRun` for a run whose status is cancelled and whose
    /// only step exited 0, with a peak memory figure (case s1-cancelled-single-step). Today the
    /// word `cancelled` lives in the top-level status key and the embedded run only. Returns the
    /// sidecar. It throws when a signing key is set, because the helper builds a default writer.
    @discardableResult
    static func cancelledSingleStepRun(in project: ProvenanceCompatScenarios.Project) async throws -> URL {
        guard ProvenanceSigningConfiguration.defaultProvider() == nil else {
            throw ScenarioError.signingKeyIsSet
        }
        let analysis = try project.folder(cancelledSingleStepAnalysisFolder)
        let input = try ProvenanceCompatScenarios.write(
            "@r1\nACGT\n+\nIIII\n",
            to: project.root.appendingPathComponent("Inputs/reads.fastq")
        )
        let output = analysis.appendingPathComponent("trimmed.fastq")
        try Data().write(to: output)

        try await CLIProvenanceSupport.recordSingleStepRun(
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
        return analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }
}
