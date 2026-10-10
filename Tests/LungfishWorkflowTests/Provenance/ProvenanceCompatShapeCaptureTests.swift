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
/// The recorder run and the two `WorkflowRun` writers are the Workflow-side shapes. The
/// single-step helper that lives in the CLI is captured by ProvenanceCompatCLICaptureTests.
@Suite("Provenance compatibility shape capture", .serialized)
struct ProvenanceCompatShapeCaptureTests {
    static let baseCommit = "81e89a306"

    // MARK: Recorder run with a readSetPlan parameter

    @Test(
        "captures a ProvenanceRecorder run whose parameters hold a readSetPlan",
        .enabled(if: ProvenanceCompatCorpus.captureCasesRequested)
    )
    func capturesRecorderRunWithReadSetPlan() async throws {
        let project = try Self.makeProject()
        defer { TestTempDirectory.cleanup(project.temporaryRoot) }
        let analysis = project.root.appendingPathComponent("Analyses/kraken2-classification", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)

        let reads1 = try Self.write("@r1/1\nACGTACGT\n+\nIIIIIIII\n", to: project.root.appendingPathComponent("Inputs/sample_R1.fastq"))
        let reads2 = try Self.write("@r1/2\nTGCATGCA\n+\nIIIIIIII\n", to: project.root.appendingPathComponent("Inputs/sample_R2.fastq"))
        let krakenOutput = try Self.write("C\tr1\t10239\t8\t10239:1\n", to: analysis.appendingPathComponent("classification.kraken"))
        let krakenReport = try Self.write("100.00\t1\t0\tR\t1\troot\n", to: analysis.appendingPathComponent("classification.kreport"))
        let brackenOutput = try Self.write("name\ttaxonomy_id\n", to: analysis.appendingPathComponent("classification.bracken"))

        let managed = PortablePath.defaultManagedRoots
        let databasePath = managed.storageRoot.appendingPathComponent("databases/kraken2/viral", isDirectory: true)
        let krakenTool = managed.toolRoot.appendingPathComponent("envs/kraken2/bin/kraken2")
        let brackenTool = managed.toolRoot.appendingPathComponent("envs/bracken/bin/bracken")

        // The pairing plan the Kraken2 pipeline puts into the run's parameters
        // (ReadSetPlan.provenanceParameters). The save below passes options without it.
        let readSetPlan: ParameterValue = .dictionary([
            "capability": .string("pairsOrSinglesPerRun"),
            "sourceLayout": .string("pairsAndSingles"),
            "pairedFragments": .integer(1),
            "mergedReads": .null,
            "orphanReads": .integer(1),
            "singleEndReads": .null,
            "mergedOrOrphanReads": .null,
            "runs": .integer(2),
            "singleReadReason": .string("orphan reads run as single reads"),
        ])
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(
            name: "Kraken2 Classification",
            parameters: [
                "goal": .string("classify"),
                "database": .string("Viral"),
                "databasePath": .file(databasePath),
                "confidence": .number(0.1),
                "threads": .integer(4),
                "pairedEnd": .boolean(true),
                "readSetPlan": readSetPlan,
            ]
        )
        await recorder.recordStep(
            runID: runID,
            toolName: "kraken2",
            toolVersion: "2.1.3",
            command: [
                krakenTool.path, "--db", databasePath.path, "--threads", "4", "--paired",
                reads1.path, reads2.path, "--output", krakenOutput.path, "--report", krakenReport.path,
            ],
            inputs: [
                ProvenanceRecorder.fileRecord(url: reads1, format: .fastq, role: .input),
                ProvenanceRecorder.fileRecord(url: reads2, format: .fastq, role: .input),
            ],
            outputs: [
                ProvenanceRecorder.fileRecord(url: krakenOutput, role: .output),
                ProvenanceRecorder.fileRecord(url: krakenReport, role: .output),
            ],
            exitCode: 0,
            wallTime: 12.5,
            peakMemoryBytes: 3_400_000_000,
            stderr: "Loading database information... done.\n1 sequences (0.00 Mbp) processed in 0.012s (0.1 Kseq/m, 0.0 Mbp/m).\n"
        )
        await recorder.recordStep(
            runID: runID,
            toolName: "bracken",
            toolVersion: "3.0",
            command: [
                brackenTool.path, "-d", databasePath.path, "-i", krakenReport.path,
                "-o", brackenOutput.path, "-r", "150", "-l", "S",
            ],
            inputs: [ProvenanceRecorder.fileRecord(url: krakenReport, role: .input)],
            outputs: [ProvenanceRecorder.fileRecord(url: brackenOutput, role: .output)],
            exitCode: 0,
            wallTime: 1.5,
            stderr: ""
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(
            runID: runID,
            to: analysis,
            options: ProvenanceOptions(
                explicit: [
                    "goal": .string("classify"),
                    "database": .string("Viral"),
                    "databasePath": .file(databasePath),
                    "confidence": .number(0.1),
                    "threads": .integer(4),
                    "pairedEnd": .boolean(true),
                ],
                defaults: ["minimumHitGroups": .integer(2)],
                resolvedDefaults: ["minimumHitGroups": .integer(2), "readFormat": .string("fastq")]
            )
        )

        let bytes = try Data(contentsOf: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s1-recorder-readsetplan",
            layoutPath: "Analyses/kraken2-classification/.lungfish-provenance.json",
            shape: "S1",
            family: "F01",
            origin: "Captured once at \(Self.baseCommit) in a temporary .lungfish project by ProvenanceCompatShapeCaptureTests. ProvenanceRecorder.beginRun with parameters that include a readSetPlan, two recordStep calls (kraken2 and bracken), completeRun, then save with explicit options that do not name the readSetPlan. The embedded legacyWorkflowRun is the only place the plan survives. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: bytes
        )
    }

    // MARK: WorkflowRun written both ways

    @Test(
        "captures a WorkflowRun written through canonicalEnvelope and ProvenanceWriter",
        .enabled(if: ProvenanceCompatCorpus.captureCasesRequested)
    )
    func capturesCanonicalEnvelopeWriterRun() throws {
        let project = try Self.makeProject()
        defer { TestTempDirectory.cleanup(project.temporaryRoot) }
        let analysis = project.root.appendingPathComponent("Analyses/variants-phase", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let run = try Self.sampleBareRun(project: project.root, analysis: analysis)

        try ProvenanceWriter(signingProvider: nil).write(run.canonicalEnvelope(), to: analysis)

        let bytes = try Data(contentsOf: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s1-canonical-envelope-run",
            layoutPath: "Analyses/variants-phase/.lungfish-provenance.json",
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
        let project = try Self.makeProject()
        defer { TestTempDirectory.cleanup(project.temporaryRoot) }
        let analysis = project.root.appendingPathComponent("Analyses/variants-phase", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let run = try Self.sampleBareRun(project: project.root, analysis: analysis)

        try run.writeSidecar(to: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        let bytes = try Data(contentsOf: analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        try ProvenanceCompatCorpus.addCapturedCase(
            id: "s3-write-sidecar-bare-run",
            layoutPath: "Analyses/variants-phase/.lungfish-provenance.json",
            shape: "S3",
            family: "F01",
            origin: "Captured once at \(Self.baseCommit) in a temporary .lungfish project by ProvenanceCompatShapeCaptureTests. A WorkflowRun modeled on the variants phase command plan, written by WorkflowRun.writeSidecar, the writer ten call sites use today. Inside the project the writer rewrote the project, tool root and storage root paths. Bytes are exactly what the writer produced, no edit. The runtime identity names the test host that ran the capture.",
            bytes: bytes
        )
    }

    // MARK: Helpers

    private struct CaptureProject {
        let temporaryRoot: URL
        let root: URL
    }

    private static func makeProject() throws -> CaptureProject {
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-compat-capture")
        let root = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CaptureProject(temporaryRoot: temporaryRoot, root: root)
    }

    @discardableResult
    private static func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A two-step run modeled on `variants phase`: typed parameters, a managed tool path,
    /// project paths, and a durable replay argv on the last step. Fixed ids and dates make
    /// the two writers see the very same run.
    private static func sampleBareRun(project: URL, analysis: URL) throws -> WorkflowRun {
        let bam = try write("BAM\u{1}bytes", to: project.appendingPathComponent("Alignments/sample.bam"))
        let reference = try write(">chr1\nACGTACGTAC\n", to: project.appendingPathComponent("Inputs/reference.fasta"))
        let rawVCF = try write("##fileformat=VCFv4.2\n", to: analysis.appendingPathComponent("raw.vcf"))
        let phasedVCF = try write("##fileformat=VCFv4.2\n##phased=true\n", to: analysis.appendingPathComponent("phased.vcf"))
        let toolRoot = PortablePath.defaultManagedRoots.toolRoot
        let gatk = toolRoot.appendingPathComponent("envs/gatk4/bin/gatk")
        let whatshap = toolRoot.appendingPathComponent("envs/whatshap/bin/whatshap")

        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let middle = started.addingTimeInterval(30)
        let finished = started.addingTimeInterval(41.5)
        let callStep = StepExecution(
            id: UUID(uuidString: "4B6D3F0C-8A57-4B0B-9C63-1E2D2F6B7A01")!,
            toolName: "gatk",
            toolVersion: "4.6.1.0",
            command: [
                gatk.path, "HaplotypeCaller", "-R", reference.path, "-I", bam.path, "-O", rawVCF.path,
                "--native-pair-hmm-threads", "2",
            ],
            inputs: [
                ProvenanceRecorder.fileRecord(url: reference, format: .fasta, role: .reference),
                ProvenanceRecorder.fileRecord(url: bam, format: .bam, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: rawVCF, format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 30,
            peakMemoryBytes: 2_100_000_000,
            stderr: "HaplotypeCaller done.",
            startTime: started,
            endTime: middle
        )
        let phaseStep = StepExecution(
            id: UUID(uuidString: "4B6D3F0C-8A57-4B0B-9C63-1E2D2F6B7A02")!,
            toolName: "whatshap",
            toolVersion: "2.3",
            command: [whatshap.path, "phase", "-o", phasedVCF.path, "--reference", reference.path, rawVCF.path, bam.path],
            durableReplayArgv: ["lungfish-cli", "variants", "phase", "--reference", reference.path, "--bam", bam.path],
            inputs: [
                ProvenanceRecorder.fileRecord(url: rawVCF, format: .vcf, role: .input),
                ProvenanceRecorder.fileRecord(url: bam, format: .bam, role: .input),
            ],
            outputs: [ProvenanceRecorder.fileRecord(url: phasedVCF, format: .vcf, role: .output)],
            exitCode: 0,
            wallTime: 11.5,
            dependsOn: [callStep.id],
            startTime: middle,
            endTime: finished
        )
        return WorkflowRun(
            id: UUID(uuidString: "4B6D3F0C-8A57-4B0B-9C63-1E2D2F6B7A00")!,
            name: "variants phase",
            startTime: started,
            endTime: finished,
            status: .completed,
            steps: [callStep, phaseStep],
            parameters: [
                "reference": .file(reference),
                "bam": .file(bam),
                "outputVCF": .file(phasedVCF),
                "sample": .string("sample-1"),
                "threads": .integer(2),
                "dryRun": .boolean(false),
                "extraGATKArgs": .string(""),
            ]
        )
    }
}
