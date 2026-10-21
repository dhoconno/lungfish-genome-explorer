// ProvenanceStepParentTests.swift - Which recorded steps an export leaves out because a CLI step ran them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P8, plan decision S6 and finding F4. `lungfish-cli import fastq` clumps and counts
// the reads itself, and `import fasta` compresses and indexes the sequence itself. The writers record
// each of those tools as a step beside the CLI step, so a script that ran every recorded step ran the
// import once through the CLI and again tool by tool, some of them on a hidden staging folder that
// no longer exists. The export plan runs the CLI step once and names the others in comments. A record
// that names the step a step ran under says so with `parentStepID`, and a released record, which has
// no such field, is read by the staging folder its tools were recorded in.
//
// The fixtures here copy the shape of the steps in the released MHC demo project, and the last group
// reads that project's own records.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProvenanceStepParentTests: XCTestCase {

    // MARK: - Fixtures

    private let project = StepParentSupport.project

    private func step(
        _ tool: String,
        _ version: String,
        argv: [String],
        durable: [String]? = nil,
        inputs: [String] = [],
        outputs: [String] = [],
        id: UUID = UUID(),
        parent: UUID? = nil
    ) -> StepExecution {
        StepExecution(
            id: id,
            toolName: tool,
            toolVersion: version,
            command: argv,
            durableReplayArgv: durable,
            inputs: inputs.map { FileRecord(path: $0, role: .input) },
            outputs: outputs.map { FileRecord(path: $0, role: .output) },
            exitCode: 0,
            wallTime: 1,
            parentStepID: parent
        )
    }

    /// The three steps a released `import fastq` record holds, spelt as the released sidecar spells
    /// them. Clumpify wrote into the import's workspace and seqkit counted the staging bundle, and
    /// the durable argv of each names the published bundle.
    private func releasedFASTQImport(_ sample: String) -> [StepExecution] {
        let source = "/data/\(sample).fastq"
        let reads = "\(project)/Imports/\(sample).lungfishfastq/\(sample).fastq.gz"
        let metadata = reads + ".lungfish-meta.json"
        let clumpify = "<tool-root>/envs/bbtools/bin/clumpify.sh"
        let importArgv = ["lungfish-cli", "import", "fastq", source, "--project", project, "--platform", "illumina"]
        return [
            step(
                "clumpify.sh", "40.02",
                argv: [clumpify, "in=\(source)", "out=\(project)/.tmp/fastq-import-22ABEAC9-A86E-446A-A518-B731F78963BF/\(sample).fastq.gz", "ow=t"],
                durable: [clumpify, "in=\(source)", "out=\(reads)", "ow=t"],
                inputs: [source], outputs: [reads]
            ),
            step(
                "lungfish import fastq", "Lungfish 2026.9.58 (5822)",
                argv: importArgv, durable: importArgv,
                inputs: [source], outputs: [reads, metadata]
            ),
            step(
                "seqkit", "2.13.0",
                argv: ["seqkit", "stats", "-a", "-T", "\(project)/Imports/.\(sample).building-6127824B-F8D3-415B-BECB-69EB777D0EA7/\(sample).fastq.gz"],
                durable: ["seqkit", "stats", "-a", "-T", reads],
                inputs: [reads], outputs: [metadata]
            ),
        ]
    }

    /// The three steps a released `import fasta` record holds. Its tool steps recorded no durable
    /// argv, so a script built from them runs bgzip and samtools on the hidden staging folder.
    private func releasedFASTAImport(_ name: String) -> [StepExecution] {
        let source = "/data/\(name).gb"
        let bundle = "\(project)/Reference Sequences/\(name).lungfishref"
        let hidden = "\(project)/Reference Sequences/.\(name).building-B15F0112-6EB2-49B3-91D6-4BA746B3B508"
        let sequence = "\(bundle)/genome/sequence.fa.gz"
        let importArgv = ["lungfish-cli", "import", "fasta", source, "--output-dir", project, "--name", name]
        return [
            step(
                "lungfish import fasta", "Lungfish 2026.9.58 (5822)",
                argv: importArgv, durable: importArgv,
                inputs: [source], outputs: [sequence, sequence + ".fai", sequence + ".gzi", "\(bundle)/manifest.json"]
            ),
            step(
                "bgzip", "1.24",
                argv: ["<tool-root>/envs/htslib/bin/bgzip", "-f", "-@", "13", "\(hidden)/genome/sequence.fa"],
                inputs: [source], outputs: [sequence]
            ),
            step(
                "samtools", "1.24",
                argv: ["<tool-root>/envs/samtools/bin/samtools", "faidx", "\(hidden)/genome/sequence.fa.gz"],
                inputs: [sequence], outputs: [sequence + ".fai", sequence + ".gzi"]
            ),
        ]
    }

    private func run(_ steps: [StepExecution]) -> WorkflowRun {
        var run = WorkflowRun(name: "step parent test", appVersion: "lungfish-cli 2026.10.10", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = steps
        return run
    }

    private func plan(_ steps: [StepExecution]) -> ProvenanceExportPlan {
        ProvenanceExportPlan(run: run(steps), replayArguments: { $0.durableReplayArgv ?? $0.command })
    }

    private func shell(_ steps: [StepExecution]) -> String {
        ProvenanceExporter(signingProvider: nil).exportShell(run(steps))
    }

    /// The lines of `script` that run something: no comment, no blank line and none of the fixed
    /// preamble every script opens with.
    private func commandLines(of script: String) -> [String] {
        StepParentSupport.commandLines(of: script)
    }

    private func makeTempDirectory() throws -> URL {
        try makeStepParentDirectory()
    }

    /// Runs `script` with bash, with a stub for each name in `stubs` first on PATH. A stub appends
    /// its own name and arguments to a log and does nothing else, so the log is what bash ran.
    private func runWithBash(
        _ script: URL,
        stubs: [String],
        in directory: URL
    ) throws -> (status: Int32, calls: [String], stderr: String) {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("calls.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        for name in stubs {
            let stub = bin.appendingPathComponent(name)
            try "#!/bin/bash\necho \"$(basename \"$0\") $*\" >> '\(log.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        environment["LUNGFISH_PROJECT"] = directory.appendingPathComponent("Project.lungfish").path
        // An exported script needs a new folder for its outputs (lane 13.45, ARCH-13.45 Q1).
        environment["OUTDIR"] = directory.appendingPathComponent("replay-outputs").path
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (process.terminationStatus, calls, stderr)
    }

    // MARK: - A released FASTQ import record

    func testReleasedFASTQImportReplaysOnlyTheCLIStep() {
        let plan = plan(releasedFASTQImport("S1"))
        XCTAssertEqual(
            plan.replayableSteps.map(\.toolName), ["lungfish import fastq"],
            "clumpify ran inside the import and seqkit counted its staging bundle, so only the import is replayed"
        )
    }

    func testShellScriptOfAReleasedFASTQImportRunsTheImportOnce() {
        let commands = commandLines(of: shell(releasedFASTQImport("S1")))
        XCTAssertEqual(commands.count, 1, "one command line, the import, but the script has \(commands)")
        XCTAssertTrue(commands.first?.hasPrefix("lungfish-cli import fastq") == true, "\(commands)")
    }

    func testBashRunsTheScriptOfAReleasedFASTQImportOnce() throws {
        let directory = try makeTempDirectory()
        let script = directory.appendingPathComponent("run.sh")
        try shell(releasedFASTQImport("S1")).write(to: script, atomically: true, encoding: .utf8)
        let outcome = try runWithBash(script, stubs: ["lungfish-cli", "clumpify.sh", "seqkit"], in: directory)
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        XCTAssertEqual(outcome.calls.count, 1, "bash ran \(outcome.calls)")
        XCTAssertTrue(outcome.calls.first?.hasPrefix("lungfish-cli import fastq") == true, "\(outcome.calls)")
    }

    // MARK: - A released FASTA import record

    func testReleasedFASTAImportReplaysOnlyTheCLIStep() {
        let plan = plan(releasedFASTAImport("Ref"))
        XCTAssertEqual(plan.replayableSteps.map(\.toolName), ["lungfish import fasta"])
    }

    func testBashRunsTheScriptOfAReleasedFASTAImportOnce() throws {
        let directory = try makeTempDirectory()
        let script = directory.appendingPathComponent("run.sh")
        try shell(releasedFASTAImport("Ref")).write(to: script, atomically: true, encoding: .utf8)
        let outcome = try runWithBash(script, stubs: ["lungfish-cli", "bgzip", "samtools"], in: directory)
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        XCTAssertEqual(outcome.calls.count, 1, "bash ran \(outcome.calls)")
        XCTAssertTrue(outcome.calls.first?.hasPrefix("lungfish-cli import fasta") == true, "\(outcome.calls)")
    }

    // MARK: - The inputs a script lists

    /// The steps of a fresh VSP2 import, as the importer records them with the import step as the
    /// parent of the others. Fastp reads the two reads and writes into the workspace, deacon reads a
    /// workspace file that no step records as an output, and clumpify reads deacon's output.
    private func freshVSP2Import() -> [StepExecution] {
        let reads = ["/data/vsp2_R1.fastq", "/data/vsp2_R2.fastq"]
        let workspace = "\(project)/.tmp/fastq-import-22ABEAC9-A86E-446A-A518-B731F78963BF"
        let bundle = "\(project)/Imports/vsp2.lungfishfastq"
        let importID = UUID()
        let importArgv = ["lungfish-cli", "import", "fastq"] + reads + ["--project", project, "--recipe", "vsp2"]
        return [
            step("fastp", "1.0.1", argv: ["fastp", "-i", reads[0], "-I", reads[1]], inputs: reads, parent: importID),
            step(
                "deacon", "0.9.0", argv: ["deacon", "filter", "\(workspace)/vsp2_mixed.fastq"],
                inputs: ["\(workspace)/vsp2_mixed.fastq"], outputs: ["\(workspace)/vsp2_clean.fastq"], parent: importID
            ),
            step(
                "clumpify.sh", "40.02", argv: ["clumpify.sh", "in=\(workspace)/vsp2_clean.fastq", "out=\(bundle)/vsp2.fastq.gz"],
                inputs: ["\(workspace)/vsp2_clean.fastq"], outputs: ["\(bundle)/vsp2.fastq.gz"], parent: importID
            ),
            step(
                "lungfish import fastq", "Lungfish 2026.9.58 (5822)", argv: importArgv, durable: importArgv,
                inputs: reads, outputs: ["\(bundle)/vsp2.fastq.gz", "\(bundle)/vsp2.fastq.gz.lungfish-meta.json"], id: importID
            ),
            step(
                "seqkit", "2.13.0", argv: ["seqkit", "stats", "\(bundle)/vsp2.fastq.gz"],
                inputs: ["\(bundle)/vsp2.fastq.gz"], outputs: ["\(bundle)/vsp2.fastq.gz.lungfish-meta.json"], parent: importID
            ),
        ]
    }

    func testAParentedVSP2ShapedRecordNamesOnlyItsTwoReads() {
        let steps = freshVSP2Import()
        XCTAssertEqual(plan(steps).primaryInputs.map(\.path), ["/data/vsp2_R1.fastq", "/data/vsp2_R2.fastq"])
        let inputLines = shell(steps).split(separator: "\n").filter { $0.hasPrefix("INPUT_") }
        XCTAssertEqual(inputLines.count, 2, "\(inputLines)")
        XCTAssertFalse(shell(steps).contains(".tmp/fastq-import-"), "the script names no file of the deleted workspace")
    }

    func testAReleasedImportKeepsTheSourceFileItsToolStepReads() {
        XCTAssertEqual(plan(releasedFASTAImport("Ref")).primaryInputs.map(\.path), ["/data/Ref.gb"])
        XCTAssertEqual(plan(releasedFASTQImport("S1")).primaryInputs.map(\.path), ["/data/S1.fastq"])
    }

    func testAnIndependentToolStepKeepsEveryInputItReads() {
        let steps = [step("fastp", "1.0.1", argv: ["fastp", "-i", "/data/raw.fastq"], inputs: ["/data/raw.fastq", "/data/adapters.fa"])]
        XCTAssertEqual(plan(steps).primaryInputs.map(\.path), ["/data/raw.fastq", "/data/adapters.fa"])
    }

    // MARK: - An independent step is never skipped

    /// A step with no recorded parent and no staging folder is read as independent and stays in the
    /// script. `variants call` records its tools this way until 2.7, although they ran inside it, so
    /// both demo variant records and the kraken2 golden export them beside the CLI step that reruns them.
    /// This test pins that reading, not a judgement that the tools are independent.
    func testToolStepsWithNoParentAndNoStagingFolderStayInTheScript() {
        let call = ["lungfish-cli", "variants", "call", "--project", project]
        let steps = [
            step("samtools", "1.24", argv: ["samtools", "view", "/data/in.bam"], inputs: ["/data/in.bam"], outputs: ["\(project)/Analyses/a/reads.bam"]),
            step("bcftools", "1.24", argv: ["bcftools", "call", "\(project)/Analyses/a/reads.bam"], inputs: ["\(project)/Analyses/a/reads.bam"], outputs: ["\(project)/Analyses/a/calls.vcf"]),
            step("lungfish variants call", "Lungfish 2026.9.58 (5822)", argv: call, durable: call, inputs: ["/data/in.bam"], outputs: ["\(project)/Analyses/a/calls.vcf"]),
        ]
        XCTAssertEqual(plan(steps).replayableSteps.map(\.toolName), ["samtools", "bcftools", "lungfish variants call"])
    }

    func testAStepInAStagingFolderNoCLIStepClaimsStaysInTheScript() {
        // The CLI step lists none of this step's outputs, so nothing says it ran inside the import.
        var steps = releasedFASTQImport("S1")
        steps.append(step(
            "seqkit", "2.13.0",
            argv: ["seqkit", "stats", "\(project)/Imports/.Other.building-AAAAAAAA-0000-0000-0000-000000000000/Other.fastq.gz"],
            inputs: ["\(project)/Imports/Other.lungfishfastq/Other.fastq.gz"],
            outputs: ["\(project)/Imports/Other.lungfishfastq/Other.fastq.gz.lungfish-meta.json"]
        ))
        XCTAssertEqual(plan(steps).replayableSteps.map(\.toolName), ["lungfish import fastq", "seqkit"])
    }

    func testStagingFolderStepsWithNoCLIStepAllStayInTheScript() {
        let steps = Array(releasedFASTAImport("Ref").dropFirst())
        XCTAssertEqual(plan(steps).replayableSteps.map(\.toolName), ["bgzip", "samtools"])
    }

    func testAnIndependentToolBeforeAnImportStaysWhenItWritesNothingTheImportWrites() {
        let before = step("fastp", "1.0.1", argv: ["fastp", "-i", "/data/raw.fastq"], inputs: ["/data/raw.fastq"], outputs: ["/data/clean.fastq"])
        let steps = [before] + releasedFASTQImport("S1")
        XCTAssertEqual(plan(steps).replayableSteps.map(\.toolName), ["fastp", "lungfish import fastq"])
    }

    // MARK: - What the plan and the scripts keep of a sub-step

    func testThePlanKeepsEachSubStepBesideItsCLIStep() throws {
        let plan = plan(releasedFASTQImport("S1"))
        XCTAssertEqual(plan.steps.map(\.toolName), ["clumpify.sh", "lungfish import fastq", "seqkit"])
        let importStep = try XCTUnwrap(plan.replayableSteps.first)
        XCTAssertEqual(plan.subSteps(of: importStep).map(\.toolName), ["clumpify.sh", "seqkit"])
        XCTAssertEqual(plan.subSteps.map(\.ranUnder), [importStep.number, importStep.number])
        XCTAssertNil(importStep.ranUnder)
    }

    func testShellScriptNamesEachSkippedStepWithItsToolAndVersionBesideTheImport() {
        let lines = shell(releasedFASTQImport("S1")).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let command = lines.firstIndex { $0.hasPrefix("lungfish-cli import fastq") }
        XCTAssertNotNil(command)
        let notes = lines.filter { $0.hasPrefix("# Step") && $0.contains("ran inside step 2") }
        XCTAssertEqual(notes, [
            "# Step 1 (clumpify.sh v40.02) ran inside step 2, so this script does not run it again.",
            "# Step 3 (seqkit v2.13.0) ran inside step 2, so this script does not run it again.",
        ])
        if let command {
            XCTAssertEqual(Array(lines[(command + 1)...].prefix(2)), notes, "the notes follow the import's command")
        }
    }

    func testPythonNextflowAndSnakemakeRunTheImportOnceAndNameTheSkippedSteps() {
        let exporter = ProvenanceExporter(signingProvider: nil)
        let run = run(releasedFASTQImport("S1"))
        let python = exporter.exportPython(run)
        XCTAssertEqual(python.components(separatedBy: "\ndef step_").count - 1, 1, "one step function")
        XCTAssertTrue(python.contains("    # Step 1 (clumpify.sh v40.02) ran inside step 2"), "the Python note is a comment in the function")
        XCTAssertTrue(python.contains("    # Step 3 (seqkit v2.13.0) ran inside step 2"))

        let nextflow = exporter.exportNextflow(run)
        XCTAssertEqual(nextflow.components(separatedBy: "\nprocess ").count - 1, 1, "one process")
        XCTAssertTrue(nextflow.contains(" * Step 1 (clumpify.sh v40.02) ran inside step 2"), "the Nextflow note is in the step's block comment")
        XCTAssertTrue(nextflow.contains(" * Step 3 (seqkit v2.13.0) ran inside step 2"))

        let snakemake = exporter.exportSnakemake(run)
        XCTAssertEqual(snakemake.components(separatedBy: "\nrule ").count - 1, 2, "rule all and one rule for the import")
        XCTAssertTrue(snakemake.contains("# Step 1 (clumpify.sh v40.02) ran inside step 2"), "the Snakemake note is a comment above the rule")
        XCTAssertTrue(snakemake.contains("# Step 3 (seqkit v2.13.0) ran inside step 2"))
    }

    func testTheMethodsTextStillNamesTheToolsTheImportRan() {
        let methods = ProvenanceExporter(signingProvider: nil).exportMethods(run(releasedFASTQImport("S1")))
        XCTAssertTrue(methods.contains("clumpify"), "clumpify ran, so the methods say so")
        XCTAssertTrue(methods.contains("seqkit"), "seqkit ran, so the methods say so")
    }

    func testASubStepAddsNoEnvironmentForTheScriptToCreate() {
        var steps = releasedFASTQImport("S1")
        let clumpify = steps[0]
        steps[0] = StepExecution(
            id: clumpify.id,
            toolName: clumpify.toolName,
            toolVersion: "40.02 (managed conda environment bbtools; executable clumpify.sh)",
            command: clumpify.command,
            durableReplayArgv: clumpify.durableReplayArgv,
            inputs: clumpify.inputs,
            outputs: clumpify.outputs,
            exitCode: 0,
            wallTime: 1
        )
        XCTAssertEqual(plan(steps).environments.map(\.name), [], "the import runs its own tools, so the script creates none")
        XCTAssertFalse(shell(steps).contains("micromamba"), "no environment is created for a step the script does not run")
    }

    // MARK: - The pin gate sees what the script runs

    private func envelope(_ steps: [StepExecution]) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            workflowName: "step parent test", toolName: "lungfish-cli",
            steps: steps.map { ProvenanceStep(stepExecution: $0) }, legacyWorkflowRun: run(steps)
        )
    }

    private func shellGate(_ steps: [StepExecution]) -> ProvenanceExportPinGate {
        ProvenanceExporter(signingProvider: nil).pinGate(
            for: envelope(steps), shape: .envelope, format: .shell, sourceSidecarURL: nil
        )
    }

    /// The released clumpify step with a version the lock does not hold, which the gate refuses
    /// when a script runs it.
    private func releasedFASTQImportWithAnUnlockedClumpify() -> [StepExecution] {
        var steps = releasedFASTQImport("S1")
        let clumpify = steps[0]
        steps[0] = StepExecution(
            id: clumpify.id,
            toolName: clumpify.toolName,
            toolVersion: "39.99",
            command: clumpify.command,
            durableReplayArgv: clumpify.durableReplayArgv,
            inputs: clumpify.inputs,
            outputs: clumpify.outputs,
            exitCode: 0,
            wallTime: 1
        )
        return steps
    }

    func testTheGateDoesNotAssessAStepTheScriptLeavesOut() {
        let steps = releasedFASTQImportWithAnUnlockedClumpify()
        let alone = shellGate([steps[0]])
        XCTAssertEqual(alone.unpinnedSteps.map(\.toolName), ["clumpify.sh"], "run by the script, the step is refused")
        let beside = shellGate(steps)
        XCTAssertEqual(beside.unpinnedSteps, [], "the import runs clumpify itself, so the script never installs it")
        XCTAssertFalse(beside.requiresOverride)
    }

    func testAnOverrideNamesNoStepTheScriptLeavesOut() {
        let steps = releasedFASTQImportWithAnUnlockedClumpify()
        let script = ProvenanceExporter(signingProvider: nil).exportShell(run(steps), allowUnpinned: true)
        XCTAssertFalse(script.contains("Not pinned"), "no step the script runs is unpinned")
        XCTAssertTrue(script.contains("# Step 1 (clumpify.sh v39.99) ran inside step 2"), "the skipped step keeps its version in a comment")
    }

    // MARK: - The released MHC demo project

    private func installedMHCProject() async throws -> (project: URL, exports: URL) {
        let workRoot = try DemoProjectFixtures.makeTempDirectory("step-parent")
        addTeardownBlock { try? FileManager.default.removeItem(at: workRoot) }
        let project = try await DemoProjectInstallHarness.install(
            DemoProjectArchiveFixtures.mhcGenotyping,
            archive: DemoProjectArchiveFixtures.mhcArchiveURL,
            under: workRoot
        )
        return (project, try DemoProjectInstallHarness.exportRoot(under: workRoot))
    }

    /// The script `provenance export --export-format shell` writes for the record at `sidecar`.
    private func exportedScript(for sidecar: URL, into exports: URL, named name: String) throws -> (text: String, url: URL) {
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: .shell,
            to: exports.appendingPathComponent(name, isDirectory: true),
            sourceSidecarURL: sidecar,
            sourceRootURL: sidecar
        )
        return (try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8), bundle.primaryArtifactURL)
    }

    func testReleasedDemoFASTQRecordExportsTheImportOnceAndNamesItsTools() async throws {
        let (project, exports) = try await installedMHCProject()
        let sidecar = project.appendingPathComponent("Imports/SIMULATED-MHC-A-pairs.lungfishfastq/.lungfish-provenance.json")
        let script = try exportedScript(for: sidecar, into: exports, named: "fastq")
        let commands = commandLines(of: script.text)
        XCTAssertEqual(commands.count, 1, "\(commands)")
        XCTAssertTrue(commands.first?.hasPrefix("lungfish-cli import fastq") == true, "\(commands)")
        XCTAssertTrue(script.text.contains("# Step 1 (clumpify.sh v40.02) ran inside step 2"), script.text)
        XCTAssertTrue(script.text.contains("# Step 3 (seqkit v2.13.0) ran inside step 2"), script.text)

        let directory = try makeTempDirectory()
        let outcome = try runWithBash(script.url, stubs: ["lungfish-cli", "clumpify.sh", "seqkit"], in: directory)
        XCTAssertEqual(outcome.status, 0, outcome.stderr)
        XCTAssertEqual(outcome.calls.count, 1, "bash ran \(outcome.calls)")
        XCTAssertTrue(outcome.calls.first?.hasPrefix("lungfish-cli import fastq") == true, "\(outcome.calls)")
    }

    func testReleasedDemoReferenceRecordExportsTheImportOnceAndNamesItsTools() async throws {
        let (project, exports) = try await installedMHCProject()
        let sidecar = project.appendingPathComponent(
            "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json"
        )
        let script = try exportedScript(for: sidecar, into: exports, named: "reference")
        let commands = commandLines(of: script.text)
        XCTAssertEqual(commands.count, 1, "\(commands)")
        XCTAssertTrue(commands.first?.hasPrefix("lungfish-cli import fasta") == true, "\(commands)")
        XCTAssertTrue(script.text.contains("# Step 2 (bgzip v1.24) ran inside step 1"), script.text)
        XCTAssertTrue(script.text.contains("# Step 3 (samtools v1.24) ran inside step 1"), script.text)
    }

    /// Every record of `project` that holds a CLI step, exported as a shell script. No command of
    /// the script names a staging folder, and an import record runs one command for each CLI step.
    private func importProblems(in project: URL) throws -> (importRecords: Int, problems: [String]) {
        var problems: [String] = []
        var importRecords = 0
        for sidecar in try DemoProvenanceReads.sidecarURLs(in: project) {
            guard let envelope = try? ProvenanceEnvelopeReader.load(fromSidecar: sidecar) else { continue }
            let run = envelope.legacyWorkflowRun(preferCanonicalSteps: true)
            let cliSteps = run.steps.filter { step in
                (step.durableReplayArgv ?? step.command).first.map { URL(fileURLWithPath: $0).lastPathComponent } == "lungfish-cli"
            }
            guard !cliSteps.isEmpty else { continue }
            let relative = sidecar.path.replacingOccurrences(of: project.path + "/", with: "")
            let commands = commandLines(of: ProvenanceExporter(signingProvider: nil).exportShell(run))
            for line in commands where line.contains(".building-") || line.contains(".tmp/fastq-import-") {
                problems.append("\(relative) runs a command in a staging folder, \(line)")
            }
            let isFASTXImport = cliSteps.contains { step in
                let argv = step.durableReplayArgv ?? step.command
                return argv.count > 2 && argv[1] == "import" && ["fastq", "fasta"].contains(argv[2])
            }
            guard isFASTXImport else { continue }
            importRecords += 1
            if commands.count != cliSteps.count {
                problems.append("\(relative) runs \(commands.count) commands for \(cliSteps.count) CLI step, \(commands)")
            }
        }
        return (importRecords, problems)
    }

    func testEveryImportRecordOfTheReleasedDemoProjectExportsWithoutItsSubSteps() async throws {
        let (project, _) = try await installedMHCProject()
        let outcome = try importProblems(in: project)
        XCTAssertGreaterThan(outcome.importRecords, 0, "the project holds import records")
        XCTAssertEqual(outcome.problems, [])
    }

    /// The sweep over all ten released archives, which sit in the golden cache and not in the
    /// repository. The unit tier never sets the variable.
    func testEveryReleasedDemoArchiveExportsItsImportsWithoutTheirSubSteps() async throws {
        guard let folderPath = ProcessInfo.processInfo.environment[DemoProjectProvenanceSweepTests.folderKey],
              !folderPath.isEmpty else {
            throw XCTSkip("Set \(DemoProjectProvenanceSweepTests.folderKey) to a folder of released demo archives.")
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let catalogue = try DemoProjectManifest.loadBundled()
        var swept: [String] = []
        var problems: [String] = []
        for project in catalogue.projects {
            let archive = folder.appendingPathComponent(project.archive.url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: archive.path),
                  (try? DemoProjectInstaller.verifyArchive(
                      at: archive,
                      expectedBytes: project.archive.bytes,
                      expectedSHA256: project.archive.sha256
                  )) != nil else { continue }
            let workRoot = try DemoProjectFixtures.makeTempDirectory("step-parent-sweep")
            defer { try? FileManager.default.removeItem(at: workRoot) }
            let installed = try await DemoProjectInstallHarness.install(project, archive: archive, under: workRoot)
            let outcome = try importProblems(in: installed)
            swept.append("\(project.id) \(outcome.importRecords) import records")
            problems += outcome.problems.map { "\(project.id) \($0)" }
        }
        print("[step-parent-sweep] \(swept.count) of \(catalogue.projects.count) catalogued archives checked")
        for line in swept { print("[step-parent-sweep] checked \(line)") }
        XCTAssertFalse(swept.isEmpty, "the folder holds no catalogued archive")
        XCTAssertEqual(problems, [])
    }

    // MARK: - The assembly bundle builder records no step under a CLI step

    /// `AssemblyBundleBuilder` stages the bundle in a `.building-` folder but writes its record
    /// after it publishes the bundle. The record holds the assembler's own steps, none of them a
    /// CLI step and none of them in a staging folder, so the builder sets no parent and the export
    /// keeps every step it records.
    func testAssemblyBundleRecordHoldsNoStagingPathAndNoSubStep() async throws {
        _ = try await ToolAvailability.require("bgzip", environment: "htslib")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("step-parent-assembly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }
        let outputDir = tempDir.appendingPathComponent("megahit-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try ">megahit_ctg_1\nACGTACGTACGTACGT\n>megahit_ctg_2\nTTTTCCCCAAAAGGGG\n"
            .write(to: outputDir.appendingPathComponent("final.contigs.fa"), atomically: true, encoding: .utf8)
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq.gz"), URL(fileURLWithPath: "/tmp/R2.fastq.gz")],
            projectName: "megahit-demo",
            outputDirectory: outputDir,
            pairedEnd: true,
            threads: 8
        )
        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: outputDir,
            commandLine: "megahit -1 R1.fastq.gz -2 R2.fastq.gz -o megahit-output",
            wallTimeSeconds: 18,
            assemblerVersion: "1.2.9"
        )
        let bundleURL = try await AssemblyBundleBuilder().build(
            result: result,
            request: request,
            provenance: ProvenanceBuilder.build(request: request, result: result, inputRecords: []),
            outputDirectory: tempDir,
            bundleName: "Managed Bundle"
        ) { _, _ in }

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        let run = envelope.legacyWorkflowRun(preferCanonicalSteps: true)
        XCTAssertFalse(run.steps.isEmpty)
        XCTAssertFalse(
            run.steps.contains(where: ProvenanceExportPlan.isInsideStagingFolder),
            "the record is written after the bundle is published, so no step names the staging folder"
        )
        XCTAssertTrue(plan(run.steps).subSteps.isEmpty, "no step of an assembly bundle record ran inside another")
    }

    // MARK: - A chain of records

    func testAChainOfTwoImportsReplaysEachImportOnceAndNothingElseOfTheirs() {
        let steps = releasedFASTQImport("S1") + releasedFASTQImport("S2") + releasedFASTAImport("Ref")
        XCTAssertEqual(
            plan(steps).replayableSteps.map(\.toolName),
            ["lungfish import fastq", "lungfish import fastq", "lungfish import fasta"]
        )
        let commands = commandLines(of: shell(steps))
        XCTAssertEqual(commands.count, 3, "\(commands)")
    }
}
