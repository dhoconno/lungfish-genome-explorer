// RunPlanOutcomeTests.swift - run --plan's interrupted, deadline and refused outcomes through the real binary (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension RunPlanTests {
    /// SWIFT fix 5 (a) and QA fix 4 of the K4 part A review: SIGTERM during the first step ends the run as interrupted,
    /// names that step, leaves no tool process and no temporary record, and never starts the second step.
    func testRunPlanSIGTERMWritesInterruptedRecordAndLeavesNoProcess() throws {
        var fixture = try RunPlanFixture()
        let sleeper = try fixture.addTool("sleeper", "echo $$ > out/pid.tmp\nmv out/pid.tmp out/pid.txt\nsleep 60")
        let never = try fixture.addTool("never", "echo never > out/never.txt")
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan([
            RunPlanFixture.step("sleeper", sleeper, outputs: ["out/pid.txt"]),
            RunPlanFixture.step("never", never, outputs: ["out/never.txt"]),
        ], manifestPin: manifest.pin)
        let pid = try fixture.start(plan, ["--image-manifest", manifest.path])
        let toolPID: pid_t
        do {
            toolPID = try ExecutorTestSupport.pid(in: fixture.planFolder + "/out", "pid.txt", timeout: 30)
        } catch {
            kill(pid, SIGKILL)
            _ = ExecutorTestSupport.waitForExit(pid, timeout: 10)
            throw error
        }
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        let run = try fixture.finish(pid, planPath: plan, timeout: 30)
        XCTAssertEqual(run.status, ExecutorExitCode.interrupted, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .interrupted)
        XCTAssertEqual(record.exitCode, ExecutorExitCode.interrupted)
        XCTAssertEqual(record.signal, SIGTERM)
        XCTAssertEqual(record.failedStepID, "sleeper")
        XCTAssertEqual(record.steps.map(\.id), ["sleeper"])
        XCTAssertEqual(record.steps.first?.outcome, .interrupted)
        XCTAssertFalse(fixture.exists("out/never.txt"))
        XCTAssertFalse(fixture.exists("logs/never.stderr"))
        XCTAssertTrue(ExecutorTestSupport.isGone(toolPID, timeout: 10), "the tool \(toolPID) is still running")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.planFolder)
            .filter { $0.hasPrefix(".run-record.json.tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    /// QA fix 5 of the K4 part A review: the plan's own deadline and grace reach the controller, which stops the tool and
    /// fails the step with K3's words (tally-r2 K4-06).
    func testPlanStepDeadlineEndsStepWithFailedRecord() throws {
        var fixture = try RunPlanFixture()
        // The PID goes to tmp/, since the controller removes a failed step's declared outputs.
        let slow = try fixture.addTool("slow", "echo $$ > tmp/pid.tmp\nmv tmp/pid.tmp tmp/pid.txt\nsleep 30")
        let manifest = try fixture.writeManifest()
        var step = RunPlanFixture.step("slow", slow)
        step.deadlineSeconds = 1
        let plan = try fixture.writePlan([step], manifestPin: manifest.pin)
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "slow")
        let stepRecord = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(stepRecord.outcome, .failed)
        XCTAssertEqual(stepRecord.deadlineSeconds, 1)
        XCTAssertEqual(stepRecord.graceSeconds, 5)
        XCTAssertLessThan(record.wallSeconds, 20)
        let reason = stepRecord.reason ?? ""
        XCTAssertTrue(reason.hasPrefix("The tool ran past its deadline of 1") && reason.hasSuffix("The executor stopped it."), reason)
        let toolPID = try ExecutorTestSupport.pid(in: fixture.planFolder + "/tmp", "pid.txt", timeout: 1)
        XCTAssertTrue(ExecutorTestSupport.isGone(toolPID, timeout: 10), "the tool \(toolPID) is still running")
    }

    /// QA fix 6 of the K4 part A review: a plan the decoder refuses (tally K4.5) is refused on the node before the
    /// self-check and before any tool, with the plan's digest recorded.
    func testRunRefusesAutoPlanBeforeAnyTool() throws {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        let original = try Data(contentsOf: URL(fileURLWithPath: plan))
        let cases: [(group: String, key: String, value: Any, reason: String)] = [
            ("storage", "clumpingTool", "auto", "This plan leaves the clumping tool as auto. A plan must name bbtools, trim-galore or none. No tool ran."),
            ("storage", "compressor", "auto", "This plan leaves the compressor as auto. A plan must name pigz or bgzip. No tool ran."),
            ("storage", "threads", 0, "This plan names 0 storage threads. A plan must name a positive thread count, since no value may mean every core. No tool ran."),
        ]
        for (group, key, value, reason) in cases {
            let field = "\(group).\(key)"
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var settings = try XCTUnwrap(object[group] as? [String: Any])
            settings[key] = value
            object[group] = settings
            let edited = try JSONSerialization.data(withJSONObject: object)
            try edited.write(to: URL(fileURLWithPath: plan))
            let run = try fixture.run(plan, ["--image-manifest", manifest])
            XCTAssertEqual(run.status, ExecutorExitCode.refused, field)
            let record = try XCTUnwrap(run.record, field)
            XCTAssertEqual(record.outcome, .refused, field)
            XCTAssertEqual(record.refusedField, field)
            XCTAssertEqual(record.reason, reason)
            XCTAssertEqual(record.plan?.sha256, PortableDigest.sha256Hex(of: edited), field)
            XCTAssertNil(record.executor.sha256, "the self-check comes after the decode")
            XCTAssertEqual(record.steps, [], field)
            XCTAssertFalse(fixture.exists("out"), field)
        }
    }

    /// QA fix 7 (a) of the K4 part A review: an input changed or deleted after the plan was written refuses the run by
    /// its entry before any tool (tally K4.4).
    func testTamperedInputRefusesBeforeAnyTool() throws {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        try RunPlanFixture.write("@r1\nACGA\n+\nIIII\n", to: fixture.planFolder + "/inputs/R1.fastq")
        let changed = try fixture.run(plan, ["--image-manifest", manifest])
        try FileManager.default.removeItem(atPath: fixture.planFolder + "/inputs/R1.fastq")
        let deleted = try fixture.run(plan, ["--image-manifest", manifest])
        for (name, run) in [("changed", changed), ("deleted", deleted)] {
            XCTAssertEqual(run.status, ExecutorExitCode.refused, name)
            let record = try XCTUnwrap(run.record, name)
            XCTAssertEqual(record.refusedField, "entries[1]", name)
            XCTAssertTrue(record.reason?.contains("inputs/R1.fastq") ?? false, name)
            XCTAssertEqual(record.inputs, [], name)
            XCTAssertEqual(record.steps, [], name)
            XCTAssertFalse(fixture.exists("out"), name)
        }
        XCTAssertEqual(deleted.record?.reason, "The plan's file inputs/R1.fastq is missing. No tool ran.")
        XCTAssertTrue(changed.record?.reason?.hasPrefix("The plan's file inputs/R1.fastq has SHA-256 ") ?? false)
    }

    #if os(Linux)
    /// QA fix 7 (b) of the K4 part A review, run by the Linux tier: a heap at or above the memory the executor observes
    /// refuses the run through the binary (tally-r2 K4-16). 60,000 GB is under the decoder's 65,536 GB cap, so the
    /// preflight and not the decoder refuses it.
    func testPlanHeapAboveMemoryRefusesWithField() throws {
        var fixture = try RunPlanFixture()
        let copy = try fixture.addTool("copy-reads", "cat \"$1\" > \"$2\"")
        let manifest = try fixture.writeManifest()
        let heapGB = 60_000
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("copy", copy, ["inputs/R1.fastq", "out/R1.fastq"], outputs: ["out/R1.fastq"])],
            manifestPin: manifest.pin,
            storage: PlanStorageSettings(
                clumpingTool: .none, compressor: .bgzip, qualityBinning: .illumina4, threads: 1, clumpifyHeapGB: heapGB,
                compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
                compressorSource: .option, qualityBinningSource: .option
            ),
            clumping: PlanClumpingChoice(
                requested: .none, resolved: .none, resolvedSource: .option, heapBytes: Int64(heapGB) * 1_073_741_824,
                reason: "explicit clumping tool selection"
            )
        )
        let run = try fixture.run(plan, ["--image-manifest", manifest.path])
        XCTAssertEqual(run.status, ExecutorExitCode.refused, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.refusedField, "storage.clumpifyHeapGB")
        XCTAssertTrue(record.reason?.contains("is not below the memory limit") ?? false, record.reason ?? "no reason")
        XCTAssertEqual(record.steps, [])
        XCTAssertFalse(fixture.exists("out"))
    }
    #endif

    /// QA fix 8 of the K4 part A review: each site-fact refusal names the position and the rule it broke, never the
    /// value, and the key bounds of the rule hold at 64 characters (tally-r2 3.1).
    func testSiteFactRefusalsNameTheRule() throws {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        let keyRule = "has a key that is not a letter followed by at most 63 letters, digits or underscores."
        let rule = { (position: Int, words: String) in "Site fact \(position) \(words) No tool ran." }
        let cases: [(arguments: [String], field: String, reason: String)] = [
            ((1...65).flatMap { ["--site-fact", "K\($0)=MARK\($0)"] }, "--site-fact 65", "Site fact 65 is over the limit of 64 site facts. No tool ran."),
            (["--site-fact", "9lives=MARKKEY"], "--site-fact 1", rule(1, keyRule)),
            (["--site-fact", "A=MARKA", "--site-fact", "B=MARK" + String(repeating: "v", count: 1021)], "--site-fact 2", rule(2, "has a value over 1024 bytes.")),
            (["--site-fact", "C=MARK\u{01}C"], "--site-fact 1", rule(1, "has a value that holds a control character.")),
            (["--site-fact", "D=MARK1", "--site-fact", "D=MARK2"], "--site-fact 2", rule(2, "repeats the key of an earlier site fact.")),
            (["--site-fact", "NOEQUALSMARK"], "--site-fact 1", rule(1, "is not KEY=VALUE.")),
            (["--site-fact", "K" + String(repeating: "k", count: 64) + "=MARK"], "--site-fact 1", rule(1, keyRule)),
            (["--site-fact", "=MARK"], "--site-fact 1", rule(1, keyRule)),
        ]
        for (arguments, field, reason) in cases {
            let run = try fixture.run(plan, ["--image-manifest", manifest] + arguments)
            XCTAssertEqual(run.status, ExecutorExitCode.refused, field)
            let record = try XCTUnwrap(run.record, field)
            XCTAssertEqual(record.refusedField, field)
            XCTAssertEqual(record.reason, reason)
            XCTAssertFalse(record.reason?.contains("MARK") ?? true, field)
            XCTAssertEqual(record.steps, [], field)
        }
        let key64 = "K" + String(repeating: "k", count: 63)
        let atBound = try fixture.run(plan, ["--image-manifest", manifest, "--site-fact", "\(key64)=v"])
        XCTAssertEqual(atBound.status, ExecutorExitCode.succeeded, atBound.stderr)
        XCTAssertEqual(atBound.record?.siteFacts, [PlanKeyValue(key: key64, value: "v")])
    }

    /// BIO fix 1 (c) of the K4 part A review (BIO-r3 R8): the record states the plan's recipe identity, with the step a
    /// switch turned off and that switch, after a succeeded run and after a refusal that came once the plan was read.
    func testRunRecordStatesRecipeAndTurnedOffSteps() throws {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        var decoded = try ExecutionPlan.decode(Data(contentsOf: URL(fileURLWithPath: plan)))
        let recipeBytes = Data("{\"id\":\"illumina-paired-cleanup\"}\n".utf8)
        try FileManager.default.createDirectory(atPath: fixture.planFolder + "/recipe", withIntermediateDirectories: true)
        try recipeBytes.write(to: URL(fileURLWithPath: fixture.planFolder + "/recipe/illumina-paired-cleanup.recipe.json"))
        let digest = PortableDigest.sha256Hex(of: recipeBytes)
        decoded.entries.append(PlanEntry(
            role: .recipe, relativePath: "recipe/illumina-paired-cleanup.recipe.json", sha256: digest, size: Int64(recipeBytes.count)
        ))
        decoded.recipe = PlanRecipeIdentity(
            id: "illumina-paired-cleanup", name: "Illumina paired cleanup", requestedName: "vsp2-target-enrichment",
            formatVersion: 2, sourceSHA256: digest, presetID: "vsp2-target-enrichment", presetName: "VSP2 target enrichment",
            switches: [
                PlanRecipeSwitch(id: "removeDuplicates", label: "Remove duplicate reads", value: true, source: "preset"),
                PlanRecipeSwitch(id: "removeRibosomalRNA", label: "Remove ribosomal RNA reads", value: false, source: "preset"),
            ],
            turnedOffSteps: [
                PlanTurnedOffStep(stepType: "deacon-ribo-filter", label: nil, activeStepsBefore: 2, switchID: "removeRibosomalRNA"),
            ]
        )
        try decoded.encoded().write(to: URL(fileURLWithPath: plan))
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        XCTAssertEqual(run.record?.recipe, decoded.recipe)
        XCTAssertEqual(run.record?.recipe?.turnedOffSteps.map(\.switchID), ["removeRibosomalRNA"])
        XCTAssertEqual(run.record?.inputs.map(\.relativePath), ["inputs/R1.fastq", "recipe/illumina-paired-cleanup.recipe.json"])
        let refused = try fixture.run(plan, ["--image-manifest", fixture.root + "/absent.json"])
        XCTAssertEqual(refused.record?.refusedField, "imageManifest")
        XCTAssertEqual(refused.record?.recipe, decoded.recipe)
    }
}
