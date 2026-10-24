// RunPlanMergedToMixedTests.swift - The merged-to-mixed step that run --plan runs itself (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

extension RunPlanTests {
    /// A plan whose first step writes one merged read and one unmerged pair, gzip-compressed when `gzipped` is true, and
    /// whose `interleave` step, with no argv and `gzip` as its tool, joins the `inputs` it names into `out/mixed.fastq`.
    /// The pinned `gzip` runs the host's gzip and logs each argv, or runs `decompressor` when one is given.
    private func mergedToMixedPlan(
        _ inputs: [String], gzipped: Bool = false, decompressor: String? = nil
    ) throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        let write = gzipped ? " | gzip -c >" : " >"
        let suffix = gzipped ? ".gz" : ""
        let split = try fixture.addTool("split-reads", """
        printf '@m1\\nACGTAC\\n+\\nIIIIII\\n'\(write) out/merged.fastq\(suffix)
        printf '@p1\\nAC\\n+\\nII\\n'\(write) out/R1.fastq\(suffix)
        printf '@p1\\nGT\\n+\\nII\\n'\(write) out/R2.fastq\(suffix)
        """)
        let gzip: PlanToolPin
        if let decompressor {
            gzip = try fixture.addTool("gzip", decompressor)
        } else {
            gzip = try fixture.addLoggingGzip()
        }
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan([
            RunPlanFixture.step(
                "split", split, outputs: ["out/merged.fastq", "out/R1.fastq", "out/R2.fastq"].map { $0 + suffix }
            ),
            PlanStep(
                id: "interleave", title: "Join merged and unmerged reads", kind: .interleave, tool: gzip, arguments: [],
                deadlineSeconds: 60, inputs: inputs, outputs: ["out/mixed.fastq"]
            ),
        ], manifestPin: manifest.pin)
        return (fixture, plan, manifest.path)
    }

    /// QA fix 4 and BIO fix 2 of the K4 part B review (tally K4.1): the merged-to-mixed step writes the merged read and
    /// then the pair, and its record holds the output's digest, the records written and the mixed-layout counts.
    func testMergedToMixedStepJoinsMergedAndPairedReads() throws {
        let (fixture, plan, manifest) = try mergedToMixedPlan(["out/merged.fastq", "out/R1.fastq", "out/R2.fastq"])
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let step = try XCTUnwrap(run.record?.steps.last)
        XCTAssertEqual(step.id, "interleave")
        XCTAssertEqual(step.outcome, .succeeded, step.reason ?? "")
        XCTAssertEqual(step.argv, [])
        XCTAssertEqual(step.outputReadCount, 3)
        XCTAssertNil(step.inputReadCount)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/out/mixed.fastq"))
        XCTAssertEqual(step.outputs, [ExecutorStepRecord.Output(
            path: "out/mixed.fastq", bytes: UInt64(bytes.count), sha256: PortableDigest.sha256Hex(of: bytes)
        )])
        XCTAssertEqual(step.storage?.mixedLayout, ExecutorMixedLayoutCounts(mergedReads: 1, pairs: 1, unpairedReads: 0))
        XCTAssertEqual(run.record?.payloads, [])
    }

    /// QA fix 4 of the K4 part B review: a merged-to-mixed step with the merged reads and only one unmerged file fails
    /// with the executor's sentence and writes nothing.
    func testMergedToMixedStepWithOneUnmergedFileFails() throws {
        let (fixture, plan, manifest) = try mergedToMixedPlan(["out/merged.fastq", "out/R1.fastq"])
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        XCTAssertEqual(run.record?.failedStepID, "interleave")
        let step = try XCTUnwrap(run.record?.steps.last)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(step.reason, "Step interleave needs the merged reads and, when present, both unmerged files.")
        XCTAssertEqual(step.outputs, [])
        XCTAssertFalse(fixture.exists("out/mixed.fastq"))
    }

    /// C4-3 C-3 (QA Q-3a, SWIFT, CHTC CH-C3-1, BIO B3-7). The merged-to-mixed step of gzip inputs records one launch for
    /// each decompressor child the reader started, in the order of the step's inputs: the pinned program's absolute
    /// path, `-dc` and the work-relative input, and its exit status. The mixed-layout counts do not change.
    func testRunRecordsDecompressorLaunchOnInterleaveStep() throws {
        let inputs = ["out/merged.fastq.gz", "out/R1.fastq.gz", "out/R2.fastq.gz"]
        let (fixture, plan, manifest) = try mergedToMixedPlan(inputs, gzipped: true)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let step = try XCTUnwrap(run.record?.steps.last)
        XCTAssertEqual(step.id, "interleave")
        XCTAssertEqual(step.outcome, .succeeded, step.reason ?? "")
        XCTAssertEqual(step.argv, [])
        XCTAssertEqual(step.outputReadCount, 3)
        XCTAssertEqual(step.storage?.mixedLayout, ExecutorMixedLayoutCounts(mergedReads: 1, pairs: 1, unpairedReads: 0))
        let gzip = try XCTUnwrap(fixture.tools.first { $0.id == "gzip" })
        let launches = try XCTUnwrap(step.storage?.launches)
        XCTAssertEqual(launches.map(\.argv), inputs.map { [gzip.path, "-dc", $0] })
        XCTAssertEqual(launches.map(\.tool), inputs.map { _ in
            ExecutorToolRecord(id: "gzip", version: "1.0", build: "t0", path: gzip.path)
        })
        XCTAssertEqual(launches.map(\.toolExitCode), [0, 0, 0])
        XCTAssertEqual(launches.map(\.outcome), [.succeeded, .succeeded, .succeeded])
        XCTAssertEqual(launches.map(\.reason), [nil, nil, nil])
        XCTAssertEqual(step.toolExitCode, 0)
        // Each launch names the one input it read with its SHA-256, and no output, since the mixed file is the
        // executor's own output (QA Q-3a, UX U-5).
        let digests = try inputs.map { path -> ExecutorFileDigest in
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/" + path))
            return ExecutorFileDigest(relativePath: path, sha256: PortableDigest.sha256Hex(of: data), size: Int64(data.count))
        }
        XCTAssertEqual(launches.map(\.inputs), digests.map { Optional([$0]) })
        XCTAssertEqual(launches.map(\.outputs), [nil, nil, nil])
    }

    /// C4-3 C-3 (QA Q-3b, SWIFT, CHTC CH-C3-1). A decompressor child that exits nonzero fails the merged-to-mixed step
    /// with no output digest, and the step's record holds that launch and its exit status.
    func testDecompressorFailureFailsInterleaveStep() throws {
        let (fixture, plan, manifest) = try mergedToMixedPlan(["out/merged.fastq.gz"], gzipped: true, decompressor: "exit 1")
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        XCTAssertEqual(run.record?.failedStepID, "interleave")
        let step = try XCTUnwrap(run.record?.steps.last)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(step.outputs, [])
        XCTAssertEqual(step.toolExitCode, 1)
        let gzip = try XCTUnwrap(fixture.tools.first { $0.id == "gzip" })
        let launches = try XCTUnwrap(step.storage?.launches)
        XCTAssertEqual(launches.map(\.argv), [[gzip.path, "-dc", "out/merged.fastq.gz"]])
        XCTAssertEqual(launches.map(\.toolExitCode), [1])
        XCTAssertEqual(launches.map(\.outcome), [.failed])
        XCTAssertEqual(
            launches.first?.reason,
            "The decompressor gzip stopped with status 1 while it read out/merged.fastq.gz."
        )
    }

    /// SWIFT Fix 4 and QA Fix 4 of the lane V review set 2. The R1 and R2 readers run together, so the order they are
    /// reaped in varies, and the record lists the launches in the order of the step's inputs. The test hands
    /// `readerLaunches` the reap order itself, so no scheduling decides it: three children reaped as R2, merged, R1
    /// come back as merged, R1, R2, and a child whose input the step does not list, reaped first of all, comes last.
    func testReaderLaunchesFollowTheStepInputsNotTheReapOrder() throws {
        let fixture = try RunPlanFixture()
        let root = URL(fileURLWithPath: fixture.planFolder)
        let inputs = ["out/merged.fastq.gz", "out/R1.fastq.gz", "out/R2.fastq.gz"]
        let stray = "out/stray.fastq.gz"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
        for (index, path) in (inputs + [stray]).enumerated() {
            try Data("read \(index)\n".utf8).write(to: root.appendingPathComponent(path))
        }
        func end(_ path: String, pid: Int32) -> ReaderChildEnd {
            ReaderChildEnd(
                label: "reader", executable: "/opt/conda/bin/gzip", arguments: ["-dc", root.path + "/" + path], pid: pid,
                exitCode: 0, signal: nil, isSuccess: true, drainExpired: false, stopped: false, escalatedToSIGKILL: false,
                wallSeconds: 0.1, environmentNames: []
            )
        }
        let reaped = [stray, inputs[2], inputs[0], inputs[1]]
        let ends = reaped.enumerated().map { end($0.element, pid: Int32(100 + $0.offset)) }

        let launches = PlanRunner.readerLaunches(ends, inputs: inputs, root: root, tools: [])

        XCTAssertEqual(launches.compactMap { $0.argv.last }, inputs + [stray], "the step's input order, then the stray")
        XCTAssertEqual(
            launches.compactMap { $0.inputs?.first?.relativePath }, inputs + [stray],
            "each launch hashes the input it read, in the same order"
        )
        XCTAssertEqual(launches.map(\.argv.count), [3, 3, 3, 3])
    }
}
