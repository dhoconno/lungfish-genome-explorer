// ProvenanceExportPinGateTests.swift - The pin gate a script export asks before it writes anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P5b, plan decisions S7, S20 and V6. The first group pins each
// reason the gate gives, from runs built in the test. The second shows that the
// gate sees what the script runs, the chain of upstream records and the step
// synthesized for a stepless record, which the per-record assessment does not.
// The third freezes the gate's verdict for every golden record, so the CLI and
// the app tests can show that both refuse the same ones.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProvenanceExportPinGateTests: XCTestCase {

    // MARK: - Fixtures

    /// One managed tool step as the pipelines record it, with the runtime identity after the version.
    private func managedStep(
        _ tool: String, version: String, environment: String, executable: String? = nil, package: String? = nil
    ) -> StepExecution {
        let executable = executable ?? tool
        var note = "managed conda environment \(environment); executable \(executable)"
        if let package { note += "; package \(package)" }
        return StepExecution(
            toolName: tool, toolVersion: "\(version) (\(note))", command: [executable, "--run"],
            inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )
    }

    private func envelope(_ steps: [StepExecution]) -> ProvenanceEnvelope {
        var run = WorkflowRun(name: "pin gate test", appVersion: "lungfish-cli 2026.10.10", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = steps
        return ProvenanceEnvelope(
            workflowName: "pin gate test", toolName: "lungfish-cli",
            steps: steps.map { ProvenanceStep(stepExecution: $0) }, legacyWorkflowRun: run
        )
    }

    private func gate(
        _ steps: StepExecution..., format: ProvenanceExportFormat = .shell,
        shape: ProvenanceEnvelopeReader.RecordShape = .envelope
    ) -> ProvenanceExportPinGate {
        ProvenanceExporter(signingProvider: nil).pinGate(
            for: envelope(steps), shape: shape, format: format, sourceSidecarURL: nil
        )
    }

    private func reasons(_ gate: ProvenanceExportPinGate) -> [ProvenanceExportPinGate.Reason] {
        gate.unpinnedSteps.map(\.reason)
    }

    // MARK: - Reasons

    func testAStepAtTheLocksVersionIsPinned() {
        let result = gate(managedStep("samtools", version: "1.24", environment: "samtools"))
        XCTAssertEqual(result.unpinnedSteps, [])
        XCTAssertFalse(result.requiresOverride)
        XCTAssertTrue(result.permitsExport(allowUnpinned: false))
        XCTAssertEqual(result.refusalLines, [])
        XCTAssertEqual(result.assessment.steps.map(\.status), [.pinnedToLock])
    }

    func testAVersionTheLockDoesNotHoldIsUnpinnedAndTheExportWritesTheRecordedVersion() {
        let result = gate(managedStep("samtools", version: "1.19", environment: "samtools"))
        XCTAssertEqual(reasons(result), [.versionNotInLock(recorded: "1.19", locked: "1.24")])
        // Never the current pin of another version (bioinformatics correction 4).
        XCTAssertEqual(result.assessment.steps.first?.exportedSpec, "bioconda::samtools=1.19")
        XCTAssertTrue(result.requiresOverride)
        XCTAssertFalse(result.permitsExport(allowUnpinned: false))
        XCTAssertTrue(result.permitsExport(allowUnpinned: true))
        // The summary names the version that ran.
        XCTAssertEqual(
            result.unpinnedSteps.first?.summary,
            "Step 1, samtools 1.19 in lge-samtools. Version 1.19 ran, but LGE installs version 1.24."
        )
    }

    func testUnknownErrorAndEmptyVersionsAreUnpinned() {
        let libmamba = "critical libmamba The given prefix does not exist: \"/x/envs/minimap2\""
        let result = gate(
            managedStep("minimap2", version: "unknown", environment: "minimap2"),
            managedStep("minimap2", version: libmamba, environment: "minimap2"),
            StepExecution(
                toolName: "samtools", toolVersion: "", command: ["/opt/conda/envs/samtools/bin/samtools", "sort"],
                inputs: [], outputs: [], exitCode: 0, wallTime: 1
            )
        )
        // The reader turns an empty version into `unknown`, so the third step reads like the first.
        XCTAssertEqual(reasons(result), [
            .versionNotRecorded(.legacySpelling("unknown")),
            .versionNotRecorded(.recordedProbeError(libmamba)),
            .versionNotRecorded(.legacySpelling("unknown")),
        ])
        XCTAssertEqual(result.unpinnedSteps.map(\.environmentName), ["lge-minimap2", "lge-minimap2", "lge-samtools"])
    }

    func testEverySpellingOfNoVersionReadsAsNotRecorded() {
        // A fact recorded as "" prints as not recorded, and so does every other spelling of no version.
        for spelling in ["", "unknown", "unresolved", "unavailable", "n/a", "system"] {
            XCTAssertEqual(
                ProvenanceExportPinGate.Reason.versionNotRecorded(.legacySpelling(spelling)).sentence,
                "Its version was not recorded.",
                spelling
            )
        }
        XCTAssertEqual(
            ProvenanceExportPinGate.Reason.versionNotRecorded(.noProbe).sentence,
            "Its version was not recorded."
        )
    }

    func testBrackenIsUnpinnableBecauseTheLockBuildsItFromSource() {
        // S20. Bracken records 3.1 and the lock's source build stays at 1.0.0.
        let result = gate(managedStep("bracken", version: "3.1", environment: "bracken"))
        XCTAssertEqual(reasons(result), [.unpinnableRuntime(.sourceBuild)])
    }

    func testAPythonRuntimeToolIsUnpinnable() {
        let result = gate(managedStep("primalscheme3", version: "3.3.0+lge.5", environment: "primalscheme3"))
        XCTAssertEqual(reasons(result), [.unpinnableRuntime(.pythonRuntime)])
    }

    func testAnEnvironmentTheLockDoesNotHoldIsUnpinned() {
        let result = gate(managedStep("gatk", version: "4.6.2.0", environment: "gatk4"))
        XCTAssertEqual(reasons(result), [.environmentNotInLock("gatk4")])
    }

    func testAStepWithNoManagedEnvironmentIsNeverGated() {
        let bare = StepExecution(
            toolName: "fastp", toolVersion: "0.24.1", command: ["fastp", "-i", "r.fq"], inputs: [], outputs: [],
            exitCode: 0, wallTime: 1
        )
        let result = gate(bare)
        XCTAssertEqual(result.assessment.steps.map(\.status), [.noEnvironmentRecorded])
        XCTAssertEqual(result.unpinnedSteps, [])
    }

    func testEachVariantOfAnEnvironmentIsAssessedWithItsOwnSpecAndName() {
        // Two samtools steps that disagree each run in their own variant (lane P5a).
        let result = gate(
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0"),
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1")
        )
        XCTAssertEqual(result.unpinnedSteps.map(\.numbers), [[1]])
        XCTAssertEqual(result.unpinnedSteps.map(\.environmentName), ["lge-samtools"])
        XCTAssertEqual(reasons(result), [.versionNotInLock(recorded: "1.23", locked: "1.24")])
        XCTAssertEqual(result.assessment.steps.map(\.exportedSpec), [
            "bioconda::samtools=1.23=aaaaaaa_0", "bioconda::samtools=1.24=h36b3a25_1",
        ])
    }

    func testARecordedSpecAtTheLocksVersionWithAnotherBuildIsPinned() {
        // The spec is what ran, and the lock holds an entry of that version.
        let result = gate(managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=hother_9"))
        XCTAssertEqual(result.assessment.steps.map(\.status), [.recordedSpecDiffersFromLock])
        XCTAssertEqual(result.unpinnedSteps, [])
    }

    // MARK: - Formats and shapes

    func testOnlyTheFourScriptFormatsAreGated() {
        let unknown = managedStep("minimap2", version: "unknown", environment: "minimap2")
        for format in ProvenanceExportFormat.allCases {
            let result = gate(unknown, format: format)
            let scripts: Set<ProvenanceExportFormat> = [.shell, .python, .nextflow, .snakemake]
            XCTAssertEqual(result.isGated, scripts.contains(format), format.cliToken)
            XCTAssertEqual(result.requiresOverride, scripts.contains(format), format.cliToken)
            XCTAssertEqual(result.permitsExport(allowUnpinned: false), !scripts.contains(format), format.cliToken)
        }
    }

    func testTheOlderRecordFormatIsNeverAScriptWithOrWithoutTheOverride() {
        let pinned = managedStep("samtools", version: "1.24", environment: "samtools")
        for shape in [ProvenanceEnvelopeReader.RecordShape.workflowRun, .primitive] {
            let result = gate(pinned, shape: shape)
            XCTAssertTrue(result.refusesOlderRecordFormat, shape.rawValue)
            XCTAssertFalse(result.requiresOverride, shape.rawValue)
            XCTAssertFalse(result.permitsExport(allowUnpinned: true), shape.rawValue)
            XCTAssertTrue(result.refusalLines.joined(separator: "\n").contains("Older record format"), shape.rawValue)
            XCTAssertTrue(gate(pinned, format: .methods, shape: shape).permitsExport(allowUnpinned: false))
            XCTAssertTrue(gate(pinned, format: .json, shape: shape).permitsExport(allowUnpinned: false))
        }
        for shape in [ProvenanceEnvelopeReader.RecordShape.envelope, .typedRecord] {
            XCTAssertTrue(gate(pinned, shape: shape).permitsExport(allowUnpinned: false), shape.rawValue)
        }
    }

    func testTheRefusalNamesEachStepItsReasonAndTheFlag() {
        let result = gate(
            managedStep("minimap2", version: "unknown", environment: "minimap2"),
            managedStep("samtools", version: "1.24", environment: "samtools"),
            managedStep("bracken", version: "3.1", environment: "bracken"),
            format: .python
        )
        XCTAssertEqual(result.refusalLines, [
            "LGE did not write the Python script, because it cannot pin the tool version of 2 steps.",
            "Step 1, minimap2 in lge-minimap2. Its version was not recorded.",
            "Step 3, bracken 3.1 in lge-bracken. LGE builds this tool from source code, which no conda package reproduces.",
            "Pass --allow-unpinned to write it anyway. The Python script and its export record then name each of these steps.",
        ])
    }

    // MARK: - What the script runs

    func testTheGateSeesTheStepSynthesizedForAStepLessRecord() {
        let stepless = ProvenanceEnvelope(
            workflowName: "map", toolName: "minimap2",
            toolVersion: "unknown (managed conda environment minimap2; executable minimap2)",
            argv: ["minimap2", "-a", "ref.fa", "reads.fq"], exitStatus: 0
        )
        XCTAssertEqual(ProvenanceExportPinAssessment.assess(stepless).steps, [], "the record itself holds no step")
        let result = ProvenanceExporter(signingProvider: nil).pinGate(
            for: stepless, shape: .envelope, format: .shell, sourceSidecarURL: nil
        )
        XCTAssertEqual(result.unpinnedSteps.map(\.toolName), ["minimap2"])
        XCTAssertEqual(reasons(result), [.versionNotRecorded(.legacySpelling("unknown"))])
    }

    func testTheGateSeesAnUnpinnedStepOfAnUpstreamRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-gate-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = directory.appendingPathComponent("aligned.bam")
        try Data("aligned reads".utf8).write(to: reads)
        let upstream = ProvenanceEnvelope(
            workflowName: "map", toolName: "minimap2",
            toolVersion: "unknown (managed conda environment minimap2; executable minimap2)",
            argv: ["minimap2", "-a", "ref.fa", "reads.fq"],
            output: try .file(url: reads, format: .bam, role: .output), exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(upstream).write(to: ProvenanceRecorder.fileSidecarURL(for: reads))
        let input = try ProvenanceFileDescriptor.file(url: reads, format: .bam, role: .input)
        let downstream = ProvenanceEnvelope(
            workflowName: "sort", toolName: "samtools", files: [input],
            steps: [ProvenanceStep(
                toolName: "samtools",
                toolVersion: "1.24 (managed conda environment samtools; executable samtools)",
                argv: ["samtools", "sort", reads.path], inputs: [input], exitStatus: 0
            )],
            exitStatus: 0
        )
        XCTAssertEqual(ProvenanceExportPinAssessment.assess(downstream).unpinnedSteps, [], "the record's own step is pinned")

        let result = ProvenanceExporter(signingProvider: nil).pinGate(
            for: downstream, shape: .envelope, format: .snakemake, sourceSidecarURL: nil
        )
        XCTAssertEqual(result.unpinnedSteps.map(\.toolName), ["minimap2"])
        XCTAssertEqual(result.unpinnedSteps.map(\.numbers), [[1]])
        XCTAssertEqual(result.assessment.steps.map(\.toolName), ["minimap2", "samtools"])
    }

    // MARK: - A classifier's environment in its runtime identity

    /// The restored kraken2 golden with `edit` applied to its steps as JSON objects.
    private func classifierRecord(_ edit: (inout [[String: Any]]) -> Void = { _ in }) throws -> ProvenanceEnvelope {
        let directory = try temporaryDirectory("pin-gate-classifier")
        let restored = try XCTUnwrap(
            GoldenProvenanceRecords.restoredCopies(in: directory)["classifiers/kraken2/lungfish-provenance.json"]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: restored)) as? [String: Any])
        var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        edit(&steps)
        object["steps"] = steps
        let edited = directory.appendingPathComponent("edited-provenance.json")
        try JSONSerialization.data(withJSONObject: object).write(to: edited)
        let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: edited))
        XCTAssertEqual(reading.shape, .envelope)
        return reading.envelope
    }

    func testAClassifierStepIsAssessedInTheEnvironmentItsRuntimeRecords() throws {
        // Bio review fix 1. ClassificationPipeline records kraken2 and Bracken with a bare argv and keeps
        // the managed environment only in the step's runtime identity.
        let exporter = ProvenanceExporter(signingProvider: nil)
        func gate(_ record: ProvenanceEnvelope) -> ProvenanceExportPinGate {
            exporter.pinGate(for: record, shape: .envelope, format: .shell, sourceSidecarURL: nil)
        }
        func kraken2Index(_ steps: [[String: Any]]) -> Int {
            steps.firstIndex { $0["toolName"] as? String == "kraken2" } ?? 0
        }

        let atLock = gate(try classifierRecord())
        let kraken2 = try XCTUnwrap(atLock.assessment.steps.first { $0.toolName == "kraken2" })
        XCTAssertEqual(kraken2.environment, "kraken2")
        XCTAssertEqual(kraken2.exportedSpec, "bioconda::kraken2=2.17.1=pl5321h158e17b_0")
        XCTAssertEqual(atLock.unpinnedSteps, [])
        // gzip inherits the record's runtime identity, whose executable is not gzip, so it gains no environment.
        XCTAssertEqual(atLock.assessment.steps.first { $0.toolName == "gzip" }?.status, .noEnvironmentRecorded)

        let older = gate(try classifierRecord { steps in steps[kraken2Index(steps)]["toolVersion"] = "2.1.3" })
        XCTAssertEqual(older.unpinnedSteps.map(\.reason), [.versionNotInLock(recorded: "2.1.3", locked: "2.17.1")])

        let withBracken = gate(try classifierRecord { steps in
            let index = kraken2Index(steps)
            var bracken = steps[index]
            bracken["id"] = UUID().uuidString
            bracken["toolName"] = "bracken"
            bracken["toolVersion"] = "3.1"
            bracken["argv"] = ["bracken", "-d", "db", "-i", "report.txt", "-o", "bracken.txt"]
            bracken["command"] = bracken["argv"]
            bracken["durableReplayArgv"] = bracken["argv"]
            bracken["inputs"] = [Any]()
            bracken["outputs"] = [Any]()
            var runtime = bracken["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime["executablePath"] = "<tool-root>/envs/bracken/bin/bracken"
            runtime["condaEnvironment"] = "bracken"
            bracken["runtimeIdentity"] = runtime
            steps.insert(bracken, at: index + 1)
        })
        XCTAssertEqual(withBracken.unpinnedSteps.map(\.toolName), ["bracken"])
        XCTAssertEqual(withBracken.unpinnedSteps.map(\.reason), [.unpinnableRuntime(.sourceBuild)])
    }

    // MARK: - Every tool of a piped step

    /// A tool as a piped step records it.
    private struct PipedTool {
        let name: String
        let executable: String
        let version: String
        let environment: String
        let verb: String
    }

    /// `writer | reader`, the writer's standard output read by the reader, as `samtools mpileup | ivar variants` runs.
    private func pipedSteps(_ writer: PipedTool, into reader: PipedTool) -> [StepExecution] {
        let pipe = "pipe:stdout:\(writer.verb)"
        func record(_ tool: PipedTool, inputs: [FileRecord], outputs: [FileRecord], argv: [String]) -> StepExecution {
            StepExecution(
                toolName: tool.name,
                toolVersion: "\(tool.version) (managed conda environment \(tool.environment); executable \(tool.executable))",
                command: [tool.executable, tool.verb] + argv, inputs: inputs, outputs: outputs, exitCode: 0, wallTime: 1
            )
        }
        return [
            record(writer, inputs: [], outputs: [FileRecord(path: pipe, role: .output)], argv: ["aln.bam"]),
            record(reader, inputs: [FileRecord(path: pipe, role: .input)], outputs: [], argv: ["-p", "variants"]),
        ]
    }

    private func pipe(_ writer: PipedTool, into reader: PipedTool) -> ProvenanceExportPinGate {
        ProvenanceExporter(signingProvider: nil).pinGate(
            for: envelope(pipedSteps(writer, into: reader)), shape: .envelope, format: .snakemake, sourceSidecarURL: nil
        )
    }

    func testAnOverriddenPipeNamesTheUnpinnedToolBesideTheStep() throws {
        let samtools = PipedTool(name: "samtools mpileup", executable: "samtools", version: "1.24", environment: "samtools", verb: "mpileup")
        let ivar = PipedTool(name: "ivar variants", executable: "ivar", version: "1.4.4", environment: "ivar", verb: "variants")
        let directory = try temporaryDirectory("pin-gate-pipe-override")
        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope(pipedSteps(samtools, into: ivar)), format: .snakemake, to: directory, sourceSidecarURL: nil,
            allowUnpinned: true
        )
        let script = try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
        XCTAssertTrue(script.contains(
            "# Not pinned (ivar variants). The script writes no environment for this tool, which ran in ivar. "
                + "Exported with --allow-unpinned.\n"
        ), script)
    }

    func testEveryToolOfAPipedStepIsAssessed() {
        // Bio review fix 2. A pipe joins two recorded steps into one script step, and the script writes the
        // environment of its first tool only.
        let samtools = PipedTool(name: "samtools mpileup", executable: "samtools", version: "1.24", environment: "samtools", verb: "mpileup")
        for version in ["unknown", "1.3.1", "1.4.4"] {
            let ivar = PipedTool(name: "ivar variants", executable: "ivar", version: version, environment: "ivar", verb: "variants")
            let result = pipe(samtools, into: ivar)
            XCTAssertEqual(result.assessment.steps.count, 1, version)
            XCTAssertEqual(result.unpinnedSteps.map(\.reason.code), ["environmentNotWritten"], version)
            XCTAssertEqual(result.unpinnedSteps.map(\.toolName), ["ivar variants"], version)
            XCTAssertEqual(result.unpinnedSteps.map(\.numbers), [[1, 2]], version)
            XCTAssertTrue(result.requiresOverride, version)
        }
        let mpileup = PipedTool(name: "bcftools mpileup", executable: "bcftools", version: "1.24", environment: "bcftools", verb: "mpileup")
        let call = PipedTool(name: "bcftools call", executable: "bcftools", version: "1.24", environment: "bcftools", verb: "call")
        XCTAssertEqual(pipe(mpileup, into: call).unpinnedSteps, [])
    }

    // MARK: - The Older record format anywhere in the chain

    /// A bare run that wrote `aligned.bam`, kept as that file's sidecar, and an envelope that sorted it.
    private func olderUpstreamChain(in directory: URL) throws -> (downstream: ProvenanceEnvelope, upstreamSidecar: URL) {
        let reads = directory.appendingPathComponent("aligned.bam")
        try Data("aligned reads".utf8).write(to: reads)
        let produced = try ProvenanceFileDescriptor.file(url: reads, format: .bam, role: .output)
        let legacy = WorkflowRun(
            name: "map", startTime: Date(timeIntervalSince1970: 100), endTime: Date(timeIntervalSince1970: 108),
            status: .completed,
            steps: [StepExecution(
                toolName: "minimap2", toolVersion: "2.31", command: ["minimap2", "-a", "ref.fa", "reads.fq"], inputs: [],
                outputs: [FileRecord(path: reads.path, sha256: produced.checksumSHA256, role: .output)], exitCode: 0, wallTime: 1
            )]
        )
        let upstreamSidecar = ProvenanceRecorder.fileSidecarURL(for: reads)
        try ProvenanceJSON.encoder.encode(legacy).write(to: upstreamSidecar)
        let input = try ProvenanceFileDescriptor.file(url: reads, format: .bam, role: .input)
        let downstream = ProvenanceEnvelope(
            workflowName: "sort", toolName: "samtools", files: [input],
            steps: [ProvenanceStep(
                toolName: "samtools", toolVersion: "1.24 (managed conda environment samtools; executable samtools)",
                argv: ["samtools", "sort", reads.path], inputs: [input], exitStatus: 0
            )],
            exitStatus: 0
        )
        return (downstream, upstreamSidecar)
    }

    func testAnUpstreamRecordInTheOlderRecordFormatRefusesTheScript() throws {
        // Bio review fix 3. The lineage resolver reads upstream records tolerantly, so a script over an
        // envelope would replay a bare run's step that the gate refuses on its own.
        let chain = try olderUpstreamChain(in: try temporaryDirectory("pin-gate-older-upstream"))
        let exporter = ProvenanceExporter(signingProvider: nil)
        let script = exporter.pinGate(for: chain.downstream, shape: .envelope, format: .snakemake, sourceSidecarURL: nil)
        XCTAssertEqual(script.assessment.steps.map(\.toolName), ["minimap2", "samtools"], "the chain reaches the bare run")
        XCTAssertTrue(script.refusesOlderRecordFormat)
        XCTAssertFalse(script.permitsExport(allowUnpinned: true))
        XCTAssertEqual(
            script.refusalLines.first?.contains(chain.upstreamSidecar.path), true, script.refusalLines.joined(separator: "\n")
        )
        let methods = exporter.pinGate(for: chain.downstream, shape: .envelope, format: .methods, sourceSidecarURL: nil)
        XCTAssertTrue(methods.permitsExport(allowUnpinned: false))
    }

    // MARK: - The recorded override

    /// Unpinned minimap2, pinned samtools and unpinned bracken.
    private func overrideEnvelope() -> ProvenanceEnvelope {
        envelope([
            managedStep("minimap2", version: "unknown", environment: "minimap2"),
            managedStep("samtools", version: "1.24", environment: "samtools"),
            managedStep("bracken", version: "3.1", environment: "bracken"),
        ])
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func exportRecord(in directory: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: directory
            .appendingPathComponent("provenance", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)))
    }

    func testTheOverrideNamesEachUnpinnedStepInTheHeaderBesideTheStepAndInTheRecord() throws {
        let summaries = [
            "Step 1, minimap2 in lge-minimap2. Its version was not recorded.",
            "Step 3, bracken 3.1 in lge-bracken. LGE builds this tool from source code, which no conda package reproduces.",
        ]
        for (format, prefix) in [(ProvenanceExportFormat.shell, "# "), (.python, ""), (.nextflow, " * "), (.snakemake, "# ")] {
            let directory = try temporaryDirectory("pin-override-\(format.cliToken)")
            let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
                overrideEnvelope(), format: format, to: directory, sourceSidecarURL: nil, allowUnpinned: true
            )
            let script = try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
            // Bioinformatics non-negotiable 3: the header names each unpinned step.
            XCTAssertTrue(script.contains("\(prefix)Exported with --allow-unpinned. LGE cannot pin the tool version\n"), script)
            for summary in summaries {
                XCTAssertTrue(script.contains("\(prefix)  \(summary)\n"), "\(format.cliToken): \(summary)")
            }
            XCTAssertFalse(script.contains("Step 2, samtools in lge-samtools"), format.cliToken)
            // Each unpinned step carries its own comment, and the pinned one none.
            let stepPrefix = format == .nextflow ? " * " : "# "
            XCTAssertEqual(script.components(separatedBy: "\(stepPrefix)Not pinned. ").count - 1, 2, format.cliToken)
            XCTAssertTrue(script.contains(
                "\(stepPrefix)Not pinned. Its version was not recorded. Exported with --allow-unpinned.\n"
            ), format.cliToken)

            let record = try exportRecord(in: directory)
            XCTAssertEqual(record.options.explicit["allowUnpinned"], .boolean(true), format.cliToken)
            XCTAssertEqual(record.options.resolvedDefaults["unpinnedSteps"], .array(summaries.map { .string($0) }), format.cliToken)
            XCTAssertEqual(record.argv.last, "--allow-unpinned", format.cliToken)
        }
    }

    func testWithoutTheOverrideAScriptCarriesNoNotesAndItsRecordNoOverride() throws {
        for format in [ProvenanceExportFormat.shell, .python, .nextflow, .snakemake] {
            let directory = try temporaryDirectory("pin-no-override-\(format.cliToken)")
            let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
                overrideEnvelope(), format: format, to: directory, sourceSidecarURL: nil
            )
            let script = try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
            XCTAssertFalse(script.contains("--allow-unpinned"), format.cliToken)
            XCTAssertFalse(script.contains("Not pinned."), format.cliToken)
            let record = try exportRecord(in: directory)
            XCTAssertNil(record.options.explicit["allowUnpinned"], format.cliToken)
            XCTAssertNil(record.options.resolvedDefaults["unpinnedSteps"], format.cliToken)
            XCTAssertFalse(record.argv.contains("--allow-unpinned"), format.cliToken)
        }
    }

    func testMethodsAndJSONExportsRecordNoOverride() throws {
        for format in [ProvenanceExportFormat.methods, .json] {
            let directory = try temporaryDirectory("pin-ungated-\(format.cliToken)")
            _ = try ProvenanceExporter(signingProvider: nil).exportBundle(
                overrideEnvelope(), format: format, to: directory, sourceSidecarURL: nil, allowUnpinned: true
            )
            let record = try exportRecord(in: directory)
            XCTAssertNil(record.options.explicit["allowUnpinned"], format.cliToken)
            XCTAssertFalse(record.argv.contains("--allow-unpinned"), format.cliToken)
        }
    }

    func testShellAndPythonNameTheEnvironmentVariantEachStepRunsIn() {
        // Shell and Python run from PATH, so each step names the environment to activate (lane P5a's review).
        var run = WorkflowRun(name: "variants", appVersion: "lungfish-cli 2026.10.10", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = [
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0"),
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"),
        ]
        let exporter = ProvenanceExporter(signingProvider: nil)
        let shell = exporter.exportShell(run)
        XCTAssertTrue(shell.contains("# Step 1: samtools v1.23 (conda environment lge-samtools)\n"), shell)
        XCTAssertTrue(shell.contains("# Step 2: samtools v1.24 (conda environment lge-samtools_2)\n"), shell)
        let python = exporter.exportPython(run)
        XCTAssertTrue(python.contains("\"\"\"samtools v1.23 (conda environment lge-samtools)\"\"\""), python)
        XCTAssertTrue(python.contains("\"\"\"samtools v1.24 (conda environment lge-samtools_2)\"\"\""), python)
    }

    func testTheHeaderSaysWhatABuildStringMeans() throws {
        let note = [
            "A spec without =<build> keeps the recorded version and leaves the build",
            "to the solver. The lock's build strings name osx-arm64 builds, so on",
            "another platform drop =<build> from a spec and keep its version.",
        ]
        var run = WorkflowRun(name: "builds", appVersion: "lungfish-cli 2026.10.10", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = [managedStep("samtools", version: "1.24", environment: "samtools")]
        let exporter = ProvenanceExporter(signingProvider: nil)
        XCTAssertTrue(exporter.exportShell(run).contains(note.map { "# \($0)\n" }.joined()))
        XCTAssertTrue(exporter.exportPython(run).contains(note.map { "\($0)\n" }.joined()))

        let nextflowDirectory = try temporaryDirectory("pin-build-note-nf")
        _ = try exporter.exportBundle(envelope(run.steps), format: .nextflow, to: nextflowDirectory, sourceSidecarURL: nil)
        let config = try String(contentsOf: nextflowDirectory.appendingPathComponent("nextflow.config"), encoding: .utf8)
        XCTAssertTrue(config.contains(note.map { "// \($0)\n" }.joined()), config)
        let snakemakeDirectory = try temporaryDirectory("pin-build-note-smk")
        _ = try exporter.exportBundle(envelope(run.steps), format: .snakemake, to: snakemakeDirectory, sourceSidecarURL: nil)
        let yaml = try String(contentsOf: snakemakeDirectory.appendingPathComponent("config.yaml"), encoding: .utf8)
        XCTAssertTrue(yaml.contains(note.map { "# \($0)\n" }.joined()), yaml)

        var bare = run
        bare.steps = [StepExecution(
            toolName: "fastp", toolVersion: "0.24.1", command: ["fastp", "-i", "r.fq"], inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )]
        XCTAssertFalse(exporter.exportShell(bare).contains("=<build>"))
    }

    func testAFactTheRecordLeftEmptyPrintsAsNotRecorded() {
        var run = WorkflowRun(name: "facts", appVersion: "", hostOS: "")
        run.steps = [StepExecution(
            toolName: "fastp", toolVersion: "0.24.1", command: ["fastp", "-i", "r.fq"], inputs: [], outputs: [], exitCode: 0, wallTime: 1
        )]
        let exporter = ProvenanceExporter(signingProvider: nil)
        for (script, prefix) in [(exporter.exportShell(run), "# "), (exporter.exportPython(run), ""),
                                 (exporter.exportNextflow(run), " * "), (exporter.exportSnakemake(run), "# ")] {
            XCTAssertTrue(script.contains("\(prefix)Generated by LGE, version not recorded\n"), script)
            XCTAssertTrue(script.contains("\(prefix)Host: not recorded\n"), script)
        }
        XCTAssertTrue(exporter.exportMethods(run).contains(
            "This recorded workflow used an LGE version and an operating system that were not recorded."
        ))
    }

    func testNoWrittenEnvironmentPinsAVersionOtherThanTheRecordedOne() throws {
        // Bioinformatics non-negotiable 3, over every restored golden record and the versions the lock lacks.
        let directory = try temporaryDirectory("pin-gate-versions")
        var records = try GoldenProvenanceRecords.restoredCopies(in: directory).compactMap { path, url in
            GoldenProvenanceRecords.cliReading(of: url).map { (path, $0.reading.envelope, Optional($0.sidecarURL)) }
        }
        records.append(("samtools 1.19", envelope([managedStep("samtools", version: "1.19", environment: "samtools")]), nil))
        records.append(("bracken 3.1", envelope([managedStep("bracken", version: "3.1", environment: "bracken")]), nil))
        let exporter = ProvenanceExporter(signingProvider: nil)
        var written = 0
        for (name, record, sidecar) in records {
            let plan = exporter.exportPlan(exporter.scriptSource(record, sourceSidecarURL: sidecar, sourceRootURL: sidecar).run)
            for step in plan.steps where step.kind == .tool {
                guard let spec = step.environment?.packageSpec, let version = CondaSpec(spec: spec)?.version else { continue }
                written += 1
                XCTAssertEqual(version, step.identity.version, "\(name) step \(step.number) writes \(spec)")
            }
        }
        XCTAssertGreaterThan(written, 2)
    }

    // MARK: - Golden records

    /// The script export verdict of each restored golden record the gate refuses, read as the CLI
    /// reads a file it is given. A row reads `<path> | <shape> | <verdict> | <steps> <tool> <reason>...`.
    /// Every other restored golden record exports without the override. Since 2.7 the demux tool steps
    /// record their version (lane B5) and the workbook receipts state their status (lane B6), so
    /// those 15 records are no longer refused.
    static let goldenRefusals: [String] = [
        "genotype/bundle/SIMULATED-MHC-haplotypes.retained_demux_provenance.json | primitive | olderRecordFormat",
        "genotype/bundle/SIMULATED-MHC-haplotypes.xlsx.export/request.json | primitive | olderRecordFormat",
        "genotype/bundle/retained-demux-genotyping-provenance.json | primitive | olderRecordFormat | 1 minimap2 versionNotRecorded.recordedAppVersion | 2 samtools sort versionNotRecorded.recordedAppVersion | 3 minimap2 versionNotRecorded.recordedAppVersion | 4 samtools sort versionNotRecorded.recordedAppVersion | 5 samtools merge versionNotRecorded.recordedAppVersion | 6 samtools index versionNotRecorded.recordedAppVersion | 7 pysam retained-read demux filter versionNotRecorded.recordedAppVersion | 10 openpyxl ONT genotype workbook report versionNotRecorded.recordedAppVersion",
        "genotype/exports/pivot.xlsx.export/request.json | primitive | olderRecordFormat",
        "genotype/exports/workbook.xlsx.export/request.json | primitive | olderRecordFormat",
    ]

    /// The workbook receipts state `status` since 2.7 (lane B6), so the committed copy reads as a typed record.
    private static let committedTypedReceipts: Set<String> = [
        "genotype/bundle/SIMULATED-MHC-haplotypes.xlsx.provenance.json",
        "genotype/exports/pivot.xlsx.provenance.json", "genotype/exports/workbook.xlsx.provenance.json",
    ]

    func testEveryCommittedGoldenRecordButTheWorkbookReceiptsReadsAsTheOlderRecordFormat() throws {
        // The golden normalizer writes "<TIMESTAMP>", "<DURATION>" and "<PID>" where a record holds a
        // date or a number, so no committed golden decodes as an envelope, and the gate refuses each
        // one as a script whatever its pins (V6). The restored copies below read as written. The
        // workbook receipts state `status` since 2.7, so they read as typed records and pass the gate.
        let urls = try GoldenProvenanceRecords.urls()
        XCTAssertEqual(urls.count, 44)
        for (path, url) in urls {
            let reading = try XCTUnwrap(GoldenProvenanceRecords.cliReading(of: url), path)
            let result = ProvenanceExporter(signingProvider: nil).pinGate(
                for: reading.reading.envelope, shape: reading.reading.shape, format: .shell,
                sourceSidecarURL: reading.sidecarURL, sourceRootURL: url
            )
            if Self.committedTypedReceipts.contains(path) {
                XCTAssertEqual(reading.reading.shape, .typedRecord, path)
                XCTAssertFalse(result.refusesOlderRecordFormat, path)
            } else {
                XCTAssertEqual(reading.reading.shape, .primitive, path)
                XCTAssertTrue(result.refusesOlderRecordFormat, path)
            }
        }
    }

    func testRestoredGoldenRecordVerdicts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-gate-golden-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try GoldenProvenanceRecords.restoredCopies(in: directory)
        XCTAssertEqual(restored.count, 44)

        var rows: [String] = []
        var steps = 0
        var unpinned = 0
        for (path, url) in restored.sorted(by: { $0.key < $1.key }) {
            let reading = try XCTUnwrap(GoldenProvenanceRecords.cliReading(of: url), path)
            let result = ProvenanceExporter(signingProvider: nil).pinGate(
                for: reading.reading.envelope, shape: reading.reading.shape, format: .shell,
                sourceSidecarURL: reading.sidecarURL, sourceRootURL: url
            )
            steps += result.assessment.steps.count
            unpinned += result.unpinnedSteps.count
            rows.append(GoldenProvenanceRecords.row(path, result))
        }
        for row in rows { print("[pin-gate] \(row)") }
        XCTAssertEqual(rows.filter { !$0.contains(" | exportable") }, Self.goldenRefusals)
        print("[pin-gate] \(rows.count) records, \(steps) script steps, \(unpinned) unpinned")
    }
}

/// The golden provenance records, the 44 records with 101 steps that
/// `ProvenanceExportPinAssessmentRecordTests` assesses, and copies of them restored to the shape they
/// were written in.
enum GoldenProvenanceRecords {
    static var root: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/golden", isDirectory: true)
    }

    /// The golden record files with steps, by path under `Tests/Fixtures/golden`.
    static func urls() throws -> [String: URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relative.hasPrefix("cli-help/"), !relative.hasPrefix("tools/"),
                  let envelope = try? ProvenanceEnvelopeReader.decode(Data(contentsOf: url)),
                  !envelope.steps.isEmpty else { continue }
            result[relative] = url
        }
        return result
    }

    /// The placeholders the golden normalizer writes where a record holds a date, a number or an id,
    /// as regular expressions, with the value a restored copy puts back.
    static let restorations: [(pattern: String, template: String)] = [
        (#""<(TIMESTAMP|GENERATED_AT)>""#, #""2026-10-10T12:00:00Z""#),
        (#""<(DURATION|PID|EPOCH)>""#, "1"),
        (#""<SIZE-[A-Z0-9]+>""#, "1"),
        (#""<UUID-([0-9])>""#, #""00000000-0000-0000-0000-00000000000$1""#),
        (#""<UUID-([0-9]{2})>""#, #""00000000-0000-0000-0000-0000000000$1""#),
    ]

    /// Each golden record copied under `directory` at its own path, with its placeholders restored.
    static func restoredCopies(in directory: URL) throws -> [String: URL] {
        var result: [String: URL] = [:]
        for (path, url) in try urls() {
            var text = try String(contentsOf: url, encoding: .utf8)
            for restoration in restorations {
                text = text.replacingOccurrences(of: restoration.pattern, with: restoration.template, options: .regularExpression)
            }
            let copy = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: copy)
            result[path] = copy
        }
        return result
    }

    /// The record the CLI reads for a file it is given, the file itself, except a typed mapping
    /// record, which only the finder converts.
    static func cliReading(of url: URL) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        if url.lastPathComponent == MappingProvenance.filename, let found = ProvenanceRecorder.findProvenanceReading(for: url) {
            return found
        }
        return ((try? ProvenanceEnvelopeReader.read(fromSidecar: url)) ?? nil).map { (url, $0) }
    }

    /// A gate verdict as one row.
    static func row(_ path: String, _ gate: ProvenanceExportPinGate) -> String {
        let verdict = gate.refusesOlderRecordFormat ? "olderRecordFormat" : (gate.requiresOverride ? "needsOverride" : "exportable")
        let steps = gate.unpinnedSteps.map { step in
            var code = step.reason.code
            if case .versionNotRecorded(let reason) = step.reason {
                switch reason {
                case .noProbe: code += ".noProbe"
                case .probeFailed: code += ".probeFailed"
                case .outputUnparseable: code += ".outputUnparseable"
                case .legacySpelling: code += ".legacySpelling"
                case .recordedProbeError: code += ".recordedProbeError"
                case .recordedAppVersion: code += ".recordedAppVersion"
                }
            }
            return "\(step.numbers.map(String.init).joined(separator: "+")) \(step.toolName) \(code)"
        }
        return ([path, gate.shape.rawValue, verdict] + steps).joined(separator: " | ")
    }
}

/// The pin gate over the records of each released demo archive in the folder LUNGFISH_DEMO_ARCHIVE_DIR
/// names, the archives `DemoProjectProvenanceSweepTests` reads. It prints which archives hold records
/// whose shell export needs the override or is the Older record format, and checks that asking the
/// gate changes no byte of the project. It skips when the folder is not named, as the unit tier does.
final class ProvenanceExportPinGateDemoSweepTests: XCTestCase {
    /// Each gate walks the record's lineage, so a large project gets an evenly spaced sample this large.
    static let sampleLimit = 400

    func testWhichDemoArchiveScriptExportsNeedTheOverride() async throws {
        let key = DemoProjectProvenanceSweepTests.folderKey
        guard let folderPath = ProcessInfo.processInfo.environment[key], !folderPath.isEmpty else {
            throw XCTSkip("Set \(key) to a folder of released demo archives to run this sweep.")
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        var swept = 0
        for project in try DemoProjectManifest.loadBundled().projects {
            let archive = folder.appendingPathComponent(project.archive.url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: archive.path) else { continue }
            try DemoProjectInstaller.verifyArchive(
                at: archive, expectedBytes: project.archive.bytes, expectedSHA256: project.archive.sha256
            )
            let workRoot = try DemoProjectFixtures.makeTempDirectory("pin-gate-sweep")
            defer { try? FileManager.default.removeItem(at: workRoot) }
            let installed = try await DemoProjectInstallHarness.install(project, archive: archive, under: workRoot)
            let before = try DemoProjectTreeSnapshot.capture(of: installed)
            let sidecars = try DemoProvenanceReads.sidecarURLs(in: installed)
            let sample = sidecars.count > Self.sampleLimit
                ? (0..<Self.sampleLimit).map { sidecars[$0 * sidecars.count / Self.sampleLimit] }
                : sidecars

            var verdicts: [String: Int] = [:]
            var reasons: [String: Int] = [:]
            var flagged: [String] = []
            for sidecar in sample {
                guard let reading = GoldenProvenanceRecords.cliReading(of: sidecar) else {
                    verdicts["unreadable", default: 0] += 1
                    continue
                }
                let gate = ProvenanceExporter(signingProvider: nil).pinGate(
                    for: reading.reading.envelope, shape: reading.reading.shape, format: .shell,
                    sourceSidecarURL: reading.sidecarURL, sourceRootURL: sidecar
                )
                let verdict = gate.refusesOlderRecordFormat ? "olderRecordFormat" : (gate.requiresOverride ? "needsOverride" : "exportable")
                verdicts[verdict, default: 0] += 1
                for step in gate.unpinnedSteps {
                    reasons["\(step.toolName) \(step.reason.code)", default: 0] += 1
                }
                if verdict != "exportable" {
                    let relative = sidecar.path.replacingOccurrences(of: installed.path + "/", with: "")
                    flagged.append("\(verdict) \(relative) (\(gate.unpinnedSteps.count) unpinned)")
                }
            }
            let after = try DemoProjectTreeSnapshot.capture(of: installed)
            XCTAssertEqual(after.differences(from: before), [], "\(project.id) changed while the gate read it")

            let counts = verdicts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("[pin-gate-demo] \(project.id) \(project.version), \(sample.count) of \(sidecars.count) records, \(counts)")
            for (reason, count) in reasons.sorted(by: { $0.key < $1.key }) {
                print("[pin-gate-demo]   \(reason), \(count) steps")
            }
            for line in flagged {
                print("[pin-gate-demo]   \(line)")
            }
            swept += 1
        }
        XCTAssertGreaterThan(swept, 0, "\(key) holds no catalogued archive")
    }
}
