// ExecutorRunAdoptionSchemaTwoTests.swift - The adopt's checks of a run of a schema 2 plan and the argv checks of
// executor-plan.md, The pipeline (Phase 5.3 lane EX-ADOPT M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// A returned folder of a schema 2 plan of one paired sample, built by hand from lane EX-TOOL's types as
/// `ExecutionPlanSchemaTwoTests` builds its plans, with no emitter: Trim Galore 2.3.0, then salmon quant on an index
/// the plan pins as a reference entry. Each `home` output is in the folder with the bytes the record states, and no
/// `staged` or `stays` output is.
struct SchemaTwoReturnedFolder {
    static let digest = String(repeating: "b", count: 64)
    static let setID = "stand-in-set-0001"
    static let indexKey = "salmon-1.10.3-k31-genome-decoys"
    static let trimGalore = PlanToolPin(id: "trim_galore", version: "2.3.0", build: "hdfd78af_0")
    static let salmon = PlanToolPin(id: "salmon", version: "1.10.3", build: "h45fbf2d_4")
    static let kept = "Duplicates: kept. LGE removes duplicates only with UMIs."
    static let polyGOff = "Poly-G trimming: off (LGE default)"
    static let polyGOn = "Poly-G trimming: on (chosen), Trim Galore 2.3.0 --poly_g"
    static let notTrimmed = "Reads not trimmed"
    static let reads = ["inputs/S1_R1.fastq.gz", "inputs/S1_R2.fastq.gz"]
    static let trimmed = ["trimmed/S1_R1_val_1.fq.gz", "trimmed/S1_R2_val_2.fq.gz"]
    static let trimReport = "trimmed/S1_R1.fastq.gz_trimming_report.txt"
    static let quantHome = ["quant/quant.sf", "quant/cmd_info.json", "quant/lib_format_counts.json", "quant/aux_info/meta_info.json"]
    static let quantLog = "quant/logs/salmon_quant.log"
    static let indexFile = "references/\(setID)/indexes/\(indexKey)/versionInfo.json"
    static let transcripts = "references/\(setID)/derived/transcripts.fa"
    static let time = "2026-11-15T12:00:00.000Z"

    let folder: URL
    let plan: ExecutionPlan
    var record: ExecutorRunRecord

    /// The chain's identity, with `trimming` and `duplicates` as every plan that makes counts states them, and
    /// `alignmentScoring` when given.
    static func pipeline(trimming: String = polyGOff, alignmentScoring: String? = nil) -> PlanPipeline {
        var values = ["trimming": trimming, "duplicates": kept]
        if let alignmentScoring { values["alignmentScoring"] = alignmentScoring }
        let labels = ["alignmentScoring": "Alignment scoring", "duplicates": "Duplicates", "trimming": "Trimming"]
        return PlanPipeline(
            id: "salmon-reads", version: 1, preset: PlanPipelinePreset(id: "bulk-salmon", name: "Bulk counts (salmon)"),
            modality: .bulk,
            route: PlanPipelineRoute(id: "salmon-reads", tool: salmon.id, toolVersion: salmon.version, settings: values),
            referenceSet: PlanPipelineReferenceSet(id: setID, layout: .lge),
            settings: values.keys.sorted().map {
                PlanPipelineSetting(id: $0, label: labels[$0] ?? $0, value: values[$0] ?? "", source: .default)
            }
        )
    }

    /// Trim Galore with the poly-G flag given, or none.
    static func trimStep(polyG flag: String? = "--no_poly_g") -> PlanStep {
        PlanStep(
            id: "trim", title: "Trim with Trim Galore", kind: .tool, tool: trimGalore,
            arguments: (flag.map { [$0] } ?? []) + ["--paired", "-o", "trimmed"] + reads,
            deadlineSeconds: ExecutionPlan.maximumDeadlineSeconds, inputs: reads, outputs: trimmed + [trimReport],
            outputPolicy: [trimmed[0]: .stays, trimmed[1]: .stays, trimReport: .home]
        )
    }

    /// salmon quant on the pinned index, returning `home` and keeping its log as `stays`.
    static func quantStep(reads input: [String] = trimmed, errorModel: Bool = false, home: [String] = quantHome) -> PlanStep {
        var policy = Dictionary(uniqueKeysWithValues: home.map { ($0, PlanOutputPolicy.home) })
        policy[quantLog] = .stays
        return PlanStep(
            id: "quant", title: "Count with salmon", kind: .tool, tool: salmon,
            arguments: ["quant", "-i", "references/\(setID)/indexes/\(indexKey)", "-l", "A", "-1", input[0], "-2", input[1],
                        "-o", "quant"] + (errorModel ? ["--errorModel"] : []),
            deadlineSeconds: ExecutionPlan.maximumDeadlineSeconds, inputs: input + [indexFile], outputs: home + [quantLog],
            outputPolicy: policy
        )
    }

    static let executorBuild = PlanExecutorBuild(
        lgeVersion: "2026.11.9", lgeCommit: String(repeating: "c", count: 40), targetTriple: "x86_64-swift-linux-musl",
        toolchainID: "swift-6.2", toolchainSHA256: digest, staticLinuxSDKID: "sdk", staticLinuxSDKSHA256: digest
    )

    static func plan(pipeline: PlanPipeline = pipeline(), steps: [PlanStep] = [trimStep(), quantStep()]) -> ExecutionPlan {
        ExecutionPlan(
            entries: [
                PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: digest, size: 10),
                PlanEntry(role: .input, relativePath: reads[0], sha256: digest, size: 20),
                PlanEntry(role: .input, relativePath: reads[1], sha256: digest, size: 20),
                PlanEntry(
                    role: .reference, relativePath: indexFile, sha256: digest, size: 30,
                    reference: PlanReferenceIdentity(setID: setID, path: "versionInfo.json", index: PlanReferenceIndex(key: indexKey, tool: salmon))
                ),
            ],
            executor: executorBuild, imageManifest: PlanImageManifestPin(sha256: digest, size: 512),
            tools: [salmon, trimGalore], recipe: nil, pipeline: pipeline,
            sample: PlanSampleValues(sampleName: "S1", originalFilenames: ["S1_R1.fastq.gz", "S1_R2.fastq.gz"], originalSizeBytes: 40, instrument: nil),
            storage: nil, clumping: nil, graceSeconds: 30, steps: steps
        )
    }

    /// A plan that makes no counts, as an index build is: no route, no modality, no input, no sample and a staged index.
    static func indexPlan() -> ExecutionPlan {
        let pipeline = PlanPipeline(
            id: "salmon-index", version: 1, preset: PlanPipelinePreset(id: "salmon-index", name: "Salmon index"), modality: nil,
            route: nil, referenceSet: PlanPipelineReferenceSet(id: setID, layout: .lge), settings: []
        )
        let staged = "index/versionInfo.json"
        let step = PlanStep(
            id: "index", title: "Build the salmon index", kind: .tool, tool: salmon, arguments: ["index", "-t", transcripts, "-i", "index"],
            deadlineSeconds: ExecutionPlan.maximumDeadlineSeconds, inputs: [transcripts], outputs: [staged], outputPolicy: [staged: .staged]
        )
        var built = Self.plan(pipeline: pipeline, steps: [step])
        built.entries = [
            built.entries[0],
            PlanEntry(role: .reference, relativePath: transcripts, sha256: digest, size: 30,
                      reference: PlanReferenceIdentity(setID: setID, path: "derived/transcripts.fa")),
        ]
        built.sampleValues = nil
        return built
    }

    /// Writes the plan, each `home` output and a succeeded record true to both into `root/<name>`. Each step's record
    /// holds the plan's argv after the tool's absolute path, as the executor records it.
    static func make(root: URL, name: String = "returned-counts", plan: ExecutionPlan = plan()) throws -> SchemaTwoReturnedFolder {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let planBytes = try plan.encoded()
        try planBytes.write(to: folder.appendingPathComponent(ExecutorRunAdoption.planFileName))
        var steps: [ExecutorStepRecord] = []
        for step in plan.steps {
            var outputs: [ExecutorStepRecord.Output] = []
            for path in step.outputs {
                let policy = step.outputPolicy?[path] ?? .stays
                let bytes = Data("\(step.id) wrote \(path)\n".utf8)
                if policy == .home {
                    let url = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url)
                }
                outputs.append(ExecutorStepRecord.Output(
                    path: path, bytes: UInt64(bytes.count), sha256: PortableDigest.sha256Hex(of: bytes), policy: policy
                ))
            }
            let tool = step.tool.map { ExecutorToolRecord(id: $0.id, version: $0.version, build: $0.build, path: "/opt/conda/bin/\($0.id)") }
            steps.append(ExecutorStepRecord(
                id: step.id, kind: step.kind, tool: tool, outcome: .succeeded, argv: [tool?.path ?? ""] + step.arguments,
                environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30, deadlineSeconds: step.deadlineSeconds,
                toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 1, outputs: outputs
            ))
        }
        let record = ExecutorRunRecord(
            outcome: .succeeded, executorArguments: ["run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: digest, size: 17, buildPin: plan.executor),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)),
            imageManifest: ExecutorImageManifestRecord(sha256: plan.imageManifest.sha256, size: plan.imageManifest.size, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2, observedLimits: [],
                subreaper: ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "0", getterResult: 0, getterValue: 1),
                orphanSweep: .subreaper
            ),
            inputs: plan.entries.filter { $0.role != .executor }, steps: steps, startedAt: time, endedAt: time, wallSeconds: 3
        )
        let returned = SchemaTwoReturnedFolder(folder: folder, plan: plan, record: record)
        try returned.write()
        return returned
    }

    /// Writes the record into the folder, after a test changed it.
    func write() throws {
        try record.encoded().write(to: folder.appendingPathComponent(ExecutorRunRecord.fileName))
    }
}

final class ExecutorRunAdoptionSchemaTwoTests: XCTestCase {
    private typealias Fixture = SchemaTwoReturnedFolder
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionSchemaTwo")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// The refusal of the adopt of counts, or nil and a failure when it takes the folder.
    private func countsRefusal(_ folder: URL, line: UInt = #line) -> ExecutorAdoptRefusal? {
        do {
            _ = try ExecutorRunAdoption.checkCounts(folder, policy: .release)
            XCTFail("The adopt of counts took the folder", line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The refusal of the FASTQ adopt, or nil and a failure when it takes the folder.
    private func fastqRefusal(_ folder: URL, line: UInt = #line) -> ExecutorAdoptRefusal? {
        do {
            _ = try ExecutorRunAdoption.check(folder, policy: .release)
            XCTFail("The FASTQ adopt took the folder", line: line)
            return nil
        } catch {
            return error
        }
    }

    private func assertRefused(_ plan: ExecutionPlan, name: String, field: String, cause: String, line: UInt = #line) throws {
        let returned = try Fixture.make(root: root, name: name, plan: plan)
        let refusal = countsRefusal(returned.folder, line: line)
        XCTAssertEqual(refusal?.field, field, line: line)
        XCTAssertEqual(refusal?.cause, cause, line: line)
        XCTAssertEqual(refusal?.reason, cause + " Nothing was imported.", line: line)
    }

    private func assertAdopted(_ plan: ExecutionPlan, name: String, line: UInt = #line) throws {
        let returned = try Fixture.make(root: root, name: name, plan: plan)
        XCTAssertNoThrow(try ExecutorRunAdoption.checkCounts(returned.folder, policy: .release), line: line)
    }

    // MARK: - M1 item 2, the checks of a schema 2 run

    /// Every `home` output comes back by its plan path in the order of the plan, and no `staged` or `stays` file is
    /// read, so their absence from the folder refuses nothing.
    func testSchemaTwoRunTakesEveryHomeOutputAndReadsNoStagedOrStaysFile() throws {
        var plan = Fixture.plan()
        plan.steps[1].outputs.append("quant/staged.bin")
        plan.steps[1].outputPolicy?["quant/staged.bin"] = .staged
        let returned = try Fixture.make(root: root, plan: plan)
        let run = try ExecutorRunAdoption.checkCounts(returned.folder, policy: .release)
        XCTAssertEqual(run.homeOutputs.map(\.path), [Fixture.trimReport] + Fixture.quantHome)
        XCTAssertEqual(run.homeOutputs.map(\.stepID), ["trim", "quant", "quant", "quant", "quant"])
        XCTAssertEqual(run.homeOutputs.map(\.stepIndex), [0, 1, 1, 1, 1])
        XCTAssertEqual(run.route, plan.pipeline?.route)
        let recorded = returned.record.steps.flatMap(\.outputs).filter { $0.policy == .home }
        XCTAssertEqual(run.homeOutputs.map(\.sha256), recorded.map(\.sha256))
        for output in run.homeOutputs {
            XCTAssertEqual(
                output.url.resolvingSymlinksInPath().path,
                returned.folder.appendingPathComponent(output.path).resolvingSymlinksInPath().path
            )
        }
        for path in Fixture.trimmed + [Fixture.quantLog, "quant/staged.bin"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: returned.folder.appendingPathComponent(path).path), path)
        }
    }

    /// One succeeded step for each planned step, in the plan's order, with the FASTQ adopt's words.
    func testSchemaTwoRunRefusesAStepTheRecordDidNotFinishOrOrder() throws {
        var returned = try Fixture.make(root: root)
        returned.record.steps[1].outcome = .failed
        try returned.write()
        var refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1]")
        XCTAssertEqual(refusal?.cause, "The run record states the outcome failed for the step quant, and a succeeded run finishes every step.")
        returned.record.steps[1].outcome = .succeeded
        returned.record.steps.swapAt(0, 1)
        try returned.write()
        refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[0]")
        XCTAssertEqual(refusal?.cause, "The run record's step 1 is not the plan's step 1, trim of kind tool.")
        returned.record.steps.swapAt(0, 1)
        returned.record.steps.removeLast()
        try returned.write()
        XCTAssertEqual(countsRefusal(returned.folder)?.field, "steps[1]")
    }

    /// Each `home` output by the record's size and SHA-256, through the resolver's path and link rules.
    func testSchemaTwoRunRefusesAHomeOutputThatIsNotTheOneTheRecordStates() throws {
        let returned = try Fixture.make(root: root)
        let quantSF = returned.folder.appendingPathComponent("quant/quant.sf")
        let original = try Data(contentsOf: quantSF)
        try Data("another count\n".utf8).write(to: quantSF)
        var refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1].outputs[0]")
        XCTAssertEqual(refusal?.cause, "The output quant/quant.sf of the step quant holds 14 bytes, and the run record states \(original.count).")
        try Data(String(decoding: original, as: UTF8.self).uppercased().utf8).write(to: quantSF)
        refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1].outputs[0]")
        XCTAssertTrue(refusal?.cause.hasPrefix("The output quant/quant.sf of the step quant has SHA-256 ") == true, refusal?.cause ?? "none")
        try FileManager.default.removeItem(at: quantSF)
        let outside = root.appendingPathComponent("outside-quant.sf")
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: quantSF, withDestinationURL: outside)
        refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1].outputs[0]")
        XCTAssertEqual(refusal?.cause, "The output quant/quant.sf of the step quant cannot be adopted. The plan path quant/quant.sf leads outside the plan's folder through a symbolic link.")
        try FileManager.default.removeItem(at: quantSF)
        refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1].outputs[0]")
        XCTAssertEqual(refusal?.cause, "The output quant/quant.sf of the step quant is missing from the folder, and the plan returns it home.")
    }

    /// `staged` and `stays` outputs are named in the record with their policy, and the record names no output the plan
    /// does not.
    func testSchemaTwoRunRefusesAnOutputTheRecordLeavesOutOrStatesWithAnotherPolicy() throws {
        var returned = try Fixture.make(root: root)
        returned.record.steps[0].outputs[2].policy = .stays
        try returned.write()
        var refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[0].outputs[2]")
        XCTAssertEqual(refusal?.cause, "The run record states the output \(Fixture.trimReport) of the step trim with policy stays, and the plan gives home.")
        returned.record.steps[0].outputs[2].policy = .home
        let log = returned.record.steps[1].outputs.removeLast()
        try returned.write()
        refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1].outputs")
        XCTAssertEqual(refusal?.cause, "The run record names no output \(Fixture.quantLog) for the step quant, which the plan's step writes with policy stays.")
        returned.record.steps[1].outputs.append(log)
        returned.record.steps[1].outputs.append(ExecutorStepRecord.Output(path: "quant/extra.txt", bytes: 1, sha256: Fixture.digest, policy: .home))
        try returned.write()
        refusal = countsRefusal(returned.folder)
        XCTAssertEqual(refusal?.field, "steps[1].outputs[5]")
        XCTAssertEqual(refusal?.cause, "The run record names the output quant/extra.txt for the step quant, which the plan's step does not write.")
    }

    /// A plan that makes no counts names `rnaseq index-adopt`, and each adopt names the other for the other's plan.
    func testEachAdoptRefusesThePlanAnotherCommandAdoptsInWordsThatNameIt() async throws {
        let index = try Fixture.make(root: root, name: "index", plan: Fixture.indexPlan())
        let indexCause = "This plan's pipeline salmon-index makes no counts, as an index build does. Record what it built with lungfish-cli rnaseq index-adopt."
        for refusal in [countsRefusal(index.folder), fastqRefusal(index.folder)] {
            XCTAssertEqual(refusal?.field, "pipeline.route")
            XCTAssertEqual(refusal?.cause, indexCause)
        }
        let counts = try Fixture.make(root: root, name: "counts")
        var refusal = fastqRefusal(counts.folder)
        XCTAssertEqual(refusal?.field, "schemaVersion")
        XCTAssertEqual(refusal?.cause, "This plan has schema version 2 and makes counts with salmon 1.10.3. Adopt it with lungfish-cli import rnaseq <folder> --adopt, since import fastq --adopt adopts the reads of a schema 1 plan only.")
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        do {
            _ = try await ExecutorRunAdoption.adopt(resultFolder: counts.folder, projectDirectory: project)
            XCTFail("import fastq --adopt took a plan that makes counts")
        } catch let error as ExecutorAdoptRefusal {
            XCTAssertEqual(error.field, "schemaVersion")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
        let reads = try ExecutorReturnedFolder.make(root: root, clumping: .bbtools)
        refusal = countsRefusal(reads.folder)
        XCTAssertEqual(refusal?.field, "schemaVersion")
        XCTAssertEqual(refusal?.cause, "This plan has schema version 1 and imports reads. Adopt it with lungfish-cli import fastq <folder> --adopt, since import rnaseq --adopt adopts the counts of a schema 2 plan only.")
    }

    // MARK: - M1 item 3, the argv checks of executor-plan.md, The pipeline

    /// Each trimmer step's recorded argv agrees with `trimming`, and a refusal names the step and prints `trimming`.
    func testTrimmerArgvThatDisagreesWithTrimmingIsRefusedNamingTheStep() throws {
        let cases: [(trimming: String, flag: String?, cause: String)] = [
            (Fixture.polyGOff, "--poly_g", "The step trim ran Trim Galore with --poly_g, and the plan states trimming as \(Fixture.polyGOff)."),
            (Fixture.polyGOn, "--no_poly_g", "The step trim ran Trim Galore with --no_poly_g, and the plan states trimming as \(Fixture.polyGOn)."),
            (Fixture.polyGOff, nil, "The step trim ran Trim Galore without --no_poly_g, and the plan states trimming as \(Fixture.polyGOff). Every trimmer call passes the poly-G setting."),
            (Fixture.polyGOn, nil, "The step trim ran Trim Galore without --poly_g, and the plan states trimming as \(Fixture.polyGOn). Every trimmer call passes the poly-G setting."),
        ]
        for (index, row) in cases.enumerated() {
            let plan = Fixture.plan(pipeline: Fixture.pipeline(trimming: row.trimming), steps: [Fixture.trimStep(polyG: row.flag), Fixture.quantStep()])
            try assertRefused(plan, name: "refused-\(index)", field: "steps[0].argv", cause: row.cause)
        }
        try assertAdopted(Fixture.plan(pipeline: Fixture.pipeline(trimming: Fixture.polyGOff)), name: "off")
        try assertAdopted(
            Fixture.plan(pipeline: Fixture.pipeline(trimming: Fixture.polyGOn), steps: [Fixture.trimStep(polyG: "--poly_g"), Fixture.quantStep()]),
            name: "on"
        )
    }

    /// `Reads not trimmed` holds no trimmer step, and a poly-G line holds one.
    func testTrimmerStepAndTrimmingStateAgree() throws {
        try assertRefused(
            Fixture.plan(pipeline: Fixture.pipeline(trimming: Fixture.notTrimmed)), name: "not-trimmed", field: "steps[0].argv",
            cause: "The step trim runs Trim Galore, and the plan states trimming as Reads not trimmed."
        )
        try assertAdopted(
            Fixture.plan(pipeline: Fixture.pipeline(trimming: Fixture.notTrimmed), steps: [Fixture.quantStep(reads: Fixture.reads)]),
            name: "untrimmed"
        )
        try assertRefused(
            Fixture.plan(steps: [Fixture.quantStep(reads: Fixture.reads)]), name: "no-trimmer", field: "pipeline.route.settings",
            cause: "The plan states trimming as \(Fixture.polyGOff), and no step runs Trim Galore."
        )
        try assertRefused(
            Fixture.plan(pipeline: Fixture.pipeline(trimming: "Poly-G trimming: auto")), name: "auto", field: "pipeline.route.settings",
            cause: "The plan states trimming as Poly-G trimming: auto, which is none of the values the adopt reads. A plan states Reads not trimmed or a poly-G line that reads off or on."
        )
    }

    /// The counting step's argv holds `--errorModel` only for `alignmentScoring` `errorModel`.
    func testCountingArgvHoldsErrorModelOnlyForErrorModelScoring() throws {
        try assertRefused(
            Fixture.plan(pipeline: Fixture.pipeline(alignmentScoring: "none"), steps: [Fixture.trimStep(), Fixture.quantStep(errorModel: true)]),
            name: "none-with-flag", field: "steps[1].argv",
            cause: "The step quant ran salmon with --errorModel, and the plan states alignmentScoring as none."
        )
        try assertRefused(
            Fixture.plan(steps: [Fixture.trimStep(), Fixture.quantStep(errorModel: true)]), name: "absent-with-flag", field: "steps[1].argv",
            cause: "The step quant ran salmon with --errorModel, and the plan states no alignmentScoring."
        )
        try assertRefused(
            Fixture.plan(pipeline: Fixture.pipeline(alignmentScoring: "errorModel")), name: "error-model-without-flag", field: "steps[1].argv",
            cause: "The step quant ran salmon without --errorModel, and the plan states alignmentScoring as errorModel."
        )
        try assertAdopted(
            Fixture.plan(pipeline: Fixture.pipeline(alignmentScoring: "errorModel"), steps: [Fixture.trimStep(), Fixture.quantStep(errorModel: true)]),
            name: "error-model"
        )
        try assertAdopted(Fixture.plan(pipeline: Fixture.pipeline(alignmentScoring: "none")), name: "none")
    }

    /// A salmon result whose counting step returns no `lib_format_counts.json` is refused, naming detectedLibraryType
    /// (FIX-EX-SCHEMA-BIO backlog 3).
    func testSalmonResultWithNoLibraryFormatReportIsRefusedNamingDetectedLibraryType() throws {
        let home = Fixture.quantHome.filter { !$0.hasSuffix("lib_format_counts.json") }
        try assertRefused(
            Fixture.plan(steps: [Fixture.trimStep(), Fixture.quantStep(home: home)]), name: "no-lib-format", field: "steps[1].outputPolicy",
            cause: "The step quant runs salmon and returns no lib_format_counts.json, so the result could not state detectedLibraryType, the library type salmon detected."
        )
    }
}
