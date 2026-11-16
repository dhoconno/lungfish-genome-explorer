// RunPlanUMICheckTests.swift - The UMI layout check as a `tool` step the plan pins to its own executor build (Phase
// 5.3 lane EX-UMI, ARCH-UMI-CHECKER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// ARCH-UMI-CHECKER item 11: a plan with the self-pin is accepted, a self-pin of another build is refused with its field,
/// a layout that fails exits non-zero with its words and the record reads `failed`, and a warning exits 0 and shows in
/// the `home` file. A stand-in counting step after the check shows that a failed check leaves the sample no counts.
final class RunPlanUMICheckTests: XCTestCase {
    private static let output = "umi-check/layout-check.json"
    private static let selfPin = PlanToolPin(id: "lungfish-executor", version: "test", build: RunPlanFixture.zeros)
    private static let motif = "ATCAATC"

    private struct Folder {
        var fixture: RunPlanFixture
        var tools: [PlanToolPin]
    }

    /// Read 1 of each pair as given and a Read 2 of the same name. The image's `pigz` is a stand-in that runs gzip.
    private func folder(read1: [String]) throws -> Folder {
        var fixture = try RunPlanFixture()
        let pigz = try fixture.addTool("pigz", "exec /usr/bin/gzip \"$@\"")
        let count = try fixture.addTool("count", "mkdir -p out\nprintf 'gene\\t1\\n' > out/counts.tsv")
        var r1 = "", r2 = ""
        for (i, read) in read1.enumerated() {
            r1 += "@p\(i) 1:N:0:A\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n"
            r2 += "@p\(i) 2:N:0:A\nACGTTGCAACGTTGCA\n+\nIIIIIIIIIIIIIIII\n"
        }
        try RunPlanFixture.write(r1, to: fixture.planFolder + "/inputs/pair1_R1.fastq")
        try RunPlanFixture.write(r2, to: fixture.planFolder + "/inputs/pair1_R2.fastq")
        return Folder(fixture: fixture, tools: [pigz, count])
    }

    /// `exact` reads with the motif and a distinct UMI, `near` with one mismatch, and the rest with none.
    private static func reads(exact: Int, near: Int, total: Int = 1000) -> [String] {
        (0..<total).map { i in
            let bases = Array("ACGT")
            let digits = String(String(i, radix: 4).reversed().map { bases[$0.wholeNumberValue ?? 0] })
            let umi = digits.padding(toLength: 16, withPad: "A", startingAt: 0)
            let start = i < exact ? motif : i < exact + near ? "ATCTATC" : "GGGCCCA"
            return start + umi + "TTTTTTTTTT"
        }
    }

    private func entry(_ folder: Folder, _ path: String) throws -> PlanEntry {
        let data = try Data(contentsOf: URL(fileURLWithPath: folder.fixture.planFolder + "/" + path))
        return PlanEntry(role: .input, relativePath: path, sha256: PortableDigest.sha256Hex(of: data), size: Int64(data.count))
    }

    private func run(_ folder: Folder, selfPin: PlanToolPin = selfPin) throws -> RunPlanFixture.Run {
        let manifest = try folder.fixture.writeManifest()
        let check = UMILayoutCheck.Arguments(
            read1: "inputs/pair1_R1.fastq", read2: "inputs/pair1_R2.fastq", decompressor: "pigz", kit: "Test kit",
            motif: Self.motif, umiLength: 16, umiRead: 1, pairs: 1000, choice: .even,
            bars: UMILayoutCheck.Bars(withinOneMismatchPass: 90, exactWarn: 90, distinctFail: 50, distinctWarn: 80),
            output: Self.output)
        let settings = ["duplicates": "Duplicates: removed with UMIs (stand-in)", "trimming": "Reads not trimmed"]
        let plan = ExecutionPlan(
            entries: [folder.fixture.executorEntry, try entry(folder, "inputs/pair1_R1.fastq"), try entry(folder, "inputs/pair1_R2.fastq")],
            executor: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: RunPlanFixture.zeros, targetTriple: "test", toolchainID: "test",
                toolchainSHA256: RunPlanFixture.zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: RunPlanFixture.zeros
            ),
            imageManifest: manifest.pin, tools: (folder.tools + [selfPin]).sorted { $0.id < $1.id }, recipe: nil,
            pipeline: PlanPipeline(
                id: "stand-in-umi", version: 1, preset: PlanPipelinePreset(id: "umi", name: "Stand-in UMI counts"), modality: .bulk,
                route: PlanPipelineRoute(id: "stand-in-umi", tool: "count", toolVersion: "1.0", settings: settings),
                referenceSet: PlanPipelineReferenceSet(id: "stand-in-set-0001", layout: .lge),
                settings: settings.keys.sorted().map { PlanPipelineSetting(id: $0, label: $0, value: settings[$0] ?? "", source: .default) }
            ),
            sample: PlanSampleValues(sampleName: "sample", originalFilenames: ["R1.fastq", "R2.fastq"], originalSizeBytes: 2),
            storage: nil, clumping: nil, graceSeconds: 5,
            steps: [
                PlanStep(id: "umi-layout-check", title: "Check the UMI layout", kind: .tool, tool: selfPin, arguments: check.argv,
                         deadlineSeconds: 600, inputs: ["inputs/pair1_R1.fastq", "inputs/pair1_R2.fastq"], outputs: [Self.output],
                         outputPolicy: [Self.output: .home]),
                PlanStep(id: "count", title: "Count", kind: .tool, tool: folder.tools[1], arguments: [], deadlineSeconds: 600,
                         inputs: ["inputs/pair1_R2.fastq"], outputs: ["out/counts.tsv"], outputPolicy: ["out/counts.tsv": .home]),
            ]
        )
        let path = folder.fixture.planFolder + "/plan.json"
        try plan.encoded().write(to: URL(fileURLWithPath: path))
        return try folder.fixture.run(path, ["--image-manifest", manifest.path])
    }

    private func report(_ folder: Folder) throws -> UMILayoutCheck.Report {
        let data = try Data(contentsOf: URL(fileURLWithPath: folder.fixture.planFolder + "/" + Self.output))
        return try JSONDecoder().decode(UMILayoutCheck.Report.self, from: data)
    }

    /// ARCH-UMI-CHECKER items 5 and 6: the step runs the executor the plan checked, and its record names LGE's build
    /// with `planPin` and the running binary's SHA-256, never an image tool.
    func testSelfPinnedCheckRunsAndItsFileComesHome() throws {
        let folder = try folder(read1: Self.reads(exact: 950, near: 0))
        let run = try run(folder)
        let record = try XCTUnwrap(run.record, run.stderr)
        XCTAssertEqual(record.outcome, .succeeded, record.reason ?? run.stderr)
        XCTAssertEqual(record.steps.map(\.id), ["umi-layout-check", "count"])
        let step = record.steps[0]
        XCTAssertEqual(step.tool, ExecutorToolRecord(
            id: "lungfish-executor", version: "test", build: RunPlanFixture.zeros, path: PlanRunner.runningExecutorPath,
            versionSource: .planPin, sha256: record.executor.sha256))
        XCTAssertEqual(Array(step.argv.dropFirst()), try UMILayoutCheck.Arguments(argv: Array(step.argv.dropFirst())).argv)
        XCTAssertEqual(step.outputs.map(\.path), [Self.output])
        XCTAssertEqual(step.outputs.map(\.policy), [.home])
        XCTAssertEqual(record.payloads.map(\.relativePath), [Self.output, "out/counts.tsv"])
        let report = try report(folder)
        XCTAssertEqual(report.verdict, .passed)
        XCTAssertEqual(report.choice, .even)
        XCTAssertEqual(report.counts.pairsRead, 1000)
        XCTAssertEqual(report.counts.exact, 950)
        XCTAssertEqual(report.counts.distinctUMIs, 950)
    }

    /// A warning exits 0, and it shows from the `home` file and not only from standard error.
    func testWarningExitsZeroAndShowsInTheHomeFile() throws {
        let folder = try folder(read1: Self.reads(exact: 880, near: 60))
        let run = try run(folder)
        let record = try XCTUnwrap(run.record, run.stderr)
        XCTAssertEqual(record.outcome, .succeeded, record.reason ?? run.stderr)
        let report = try report(folder)
        XCTAssertEqual(report.verdict, .warned)
        XCTAssertEqual(report.reasons.map(\.code), [.exactUnderBar])
        XCTAssertTrue(report.words.contains("Warning: Read 1 starts with ATCAATC exactly in 880 of 1,000 pairs read (88.0%), under 90%."), report.words)
    }

    /// executor-plan.md, The UMI layout check: a failure exits non-zero with its words, the record reads `failed` with
    /// the check as `failedStepID` and the words in `reason`, and the sample gets no counts.
    func testFailedCheckStopsTheSampleWithItsWords() throws {
        let folder = try folder(read1: Self.reads(exact: 0, near: 0))
        let run = try run(folder)
        let record = try XCTUnwrap(run.record, run.stderr)
        XCTAssertEqual(run.status, ExecutorExitCode.failed)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "umi-layout-check")
        let words = "UMI layout check failed: 0 of 1,000 pairs read (0.0%) start within one mismatch of ATCAATC, under the 90% the Test kit preset needs."
        XCTAssertTrue(record.reason?.contains(words) == true, record.reason ?? "")
        XCTAssertTrue(record.steps.first?.stderrTail.contains(words) == true, record.steps.first?.stderrTail ?? "")
        XCTAssertEqual(record.steps.first?.toolExitCode, ExecutorExitCode.failed)
        XCTAssertEqual(record.steps.map(\.id), ["umi-layout-check"])
        XCTAssertTrue(record.payloads.isEmpty)
        XCTAssertFalse(folder.fixture.exists("out/counts.tsv"))
    }

    /// ARCH-UMI-CHECKER item 5: a self-pin whose build is not the plan's executor is refused before any tool starts.
    func testSelfPinOfAnotherBuildIsRefusedWithItsField() throws {
        let folder = try folder(read1: Self.reads(exact: 950, near: 0))
        let other = PlanToolPin(id: "lungfish-executor", version: "test", build: String(repeating: "1", count: 64))
        let record = try XCTUnwrap(try run(folder, selfPin: other).record)
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.refusedField, "steps[0].tool")
        XCTAssertTrue(record.reason?.hasSuffix("No tool ran.") == true, record.reason ?? "")
        XCTAssertTrue(record.steps.isEmpty)
        XCTAssertFalse(folder.fixture.exists(Self.output))
    }

    /// ARCH-UMI-CHECKER item 3: a missing flag exits 64 with the usage.
    func testMissingFlagExitsWithTheUsage() throws {
        let fixture = try RunPlanFixture()
        let pid = try ExecutorTestSupport.spawn(fixture.binary, ["umi-layout-check", "--read1", "a.fastq"], folder: fixture.root)
        let exit = try XCTUnwrap(ExecutorTestSupport.waitForExit(pid, timeout: 30))
        XCTAssertEqual(exit.termination, .exited(code: ExecutorExitCode.usage))
    }
}
