import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// The storage step of `run --plan` with a `/bin/sh` clumpify in the tool manifest (lane K4, milestone M4).
extension RunPlanTests {
    /// A one-step plan that stores `inputs/R1.fastq` with BBTools at a 1 GB heap, through the clumpify `body`, within
    /// the step's `deadline` in seconds. It pins the `gzip` that reads the stored payload (SWIFT fix 2 of the K4 part B
    /// review).
    func clumpifyPlan(_ body: String, deadline: Double = 60) throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        let clumpify = try fixture.addTool("clumpify.sh", body)
        // BIO N3. The plan pins the bgzip BBTools writes through, and it answers `bgzip -h` as BBTools' probe asks.
        let bgzip = try fixture.addTool("bgzip", "[ \"$1\" = \"-h\" ]")
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest()
        let step = PlanStep(
            id: "storage", title: "Store reads", kind: .storage, tool: clumpify, arguments: [],
            environment: [PlanEnvironmentVariable(name: "_JAVA_OPTIONS", value: "-Xmx1g")], deadlineSeconds: deadline,
            inputs: ["inputs/R1.fastq"], outputs: ["out/sample.fastq.gz"]
        )
        let plan = try fixture.writePlan(
            [step], manifestPin: manifest.pin,
            storage: PlanStorageSettings(
                clumpingTool: .bbtools, compressor: .bgzip, qualityBinning: .illumina4, threads: 1, clumpifyHeapGB: 1,
                compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
                compressorSource: .option, qualityBinningSource: .option
            ),
            clumping: PlanClumpingChoice(
                requested: .bbtools, resolved: .bbtools, resolvedSource: .option, heapBytes: 1_073_741_824,
                reason: "explicit clumping tool selection"
            ),
            pins: [bgzip, gzip]
        )
        return (fixture, plan, manifest.path)
    }

    /// QA N2-T4 (QA-r3). Clumpify's group count and memory lines reach the record, with the plan's heap in its argv and
    /// in `_JAVA_OPTIONS` (tally-r2 K4-07, K4-10).
    func testRunRecordKeepsClumpifyGroupsUnderPlanHeap() throws {
        let (fixture, plan, manifest) = try clumpifyPlan("""
        for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        printf '%s\\n' "$@" > logs/clumpify.argv
        printf '%s\\n' "$_JAVA_OPTIONS" > logs/clumpify.java
        gzip -c < "$IN" > "$OUT"
        printf 'Read Estimate: 999900\\nMemory Estimate: 656 MB\\nMemory Available: 28 MB\\nSet groups to 209\\n' >&2
        """)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .succeeded, record.reason ?? "")
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .succeeded, step.reason ?? "")
        let argv = fixture.text("logs/clumpify.argv").split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, PortableStoragePlan.clumpifyArguments(
            input: URL(fileURLWithPath: "inputs/R1.fastq"), output: URL(fileURLWithPath: "out/sample.fastq.gz"),
            interleaved: false, heapGB: 1, threads: 1, qualityBinning: .illumina4
        ).map { $0.replacingOccurrences(of: FileManager.default.currentDirectoryPath + "/", with: "") })
        for expected in ["-Xmx1g", "groups=auto", "reorder", BBToolsOutOfMemory.flag] {
            XCTAssertTrue(argv.contains(expected), expected)
        }
        XCTAssertEqual(step.argv, [fixture.tools[0].path] + argv)
        XCTAssertEqual(fixture.text("logs/clumpify.java"), "-Xmx1g\n")
        XCTAssertTrue(step.environmentNames.contains("_JAVA_OPTIONS"))
        let storage = try XCTUnwrap(step.storage)
        XCTAssertEqual(storage.clumpifyGroups, 209)
        XCTAssertEqual(storage.clumpifyMemoryEstimateLine, "Memory Estimate: 656 MB")
        XCTAssertEqual(storage.clumpifyMemoryAvailableLine, "Memory Available: 28 MB")
        XCTAssertEqual(storage.writer?.name, "bgzip")
        XCTAssertEqual(storage.writer?.tool?.id, "bgzip")
        XCTAssertEqual(storage.effectiveCompressionLevel, 4)
        XCTAssertEqual(storage.launches?.map(\.tool.id), ["bgzip", "clumpify.sh"])
        XCTAssertEqual(storage.launches?.first?.argv, [fixture.tools[1].path, "-h"])
        XCTAssertEqual(step.inputReadCount, 1)
        XCTAssertEqual(step.outputReadCount, 1)
        XCTAssertEqual(step.outputs.map(\.path), ["out/sample.fastq.gz"])
    }

    /// Tally-r2 K4-09. A clumpify that runs out of heap fails its step with its last stderr lines and no payload digest,
    /// and nothing else stores the reads.
    func testClumpifyOutOfMemoryFailsStepWithRecord() throws {
        let (fixture, plan, manifest) = try clumpifyPlan("""
        echo 'java.lang.OutOfMemoryError: Java heap space' >&2
        echo 'Terminating due to java.lang.OutOfMemoryError: Java heap space' >&2
        exit 3
        """)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.failed, run.stderr)
        let record = try XCTUnwrap(run.record)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failedStepID, "storage")
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.outcome, .failed)
        XCTAssertEqual(step.toolExitCode, BBToolsOutOfMemory.exitStatus)
        XCTAssertEqual(step.outputs, [])
        XCTAssertNil(step.outputReadCount)
        XCTAssertTrue(step.stderrTail.contains("Terminating due to java.lang.OutOfMemoryError: Java heap space"), step.stderrTail)
        XCTAssertTrue(step.reason?.contains("ran out of memory in its 1 GB Java heap") == true, step.reason ?? "")
        XCTAssertEqual(step.storage?.launches?.map(\.tool.id), ["bgzip", "clumpify.sh"])
    }
}
