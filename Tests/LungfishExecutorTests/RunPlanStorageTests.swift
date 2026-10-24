import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// The storage step of `run --plan` with a `/bin/sh` clumpify in the tool manifest (lane K4, milestone M4).
extension RunPlanTests {
    /// A one-step plan that stores `inputs/R1.fastq` with BBTools at a 1 GB heap, through the clumpify `body`, within
    /// the step's `deadline` in seconds. It pins the `gzip` that reads the stored payload (SWIFT fix 2 of the K4 part B
    /// review).
    func clumpifyPlan(
        _ body: String, deadline: Double = 60, bgzip bgzipBody: String = "[ \"$1\" = \"-h\" ] && echo 'Version: 1.0'",
        manifestListsBgzip: Bool = true
    ) throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        let clumpify = try fixture.addTool("clumpify.sh", body)
        // BIO N3. The plan pins the bgzip BBTools writes through, and by default it answers `bgzip -h` as BBTools' probe
        // asks, with the `Version:` line of the version the plan pins (C4-3 C-4), and the manifest lists it.
        let bgzip = try fixture.addTool("bgzip", bgzipBody)
        let gzip = try fixture.addLoggingGzip()
        let manifest = try fixture.writeManifest(excluding: manifestListsBgzip ? [] : ["bgzip"])
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
        XCTAssertEqual(
            step.reason,
            "clumpify.sh ran out of memory in its 1 GB Java heap and stopped with status \(BBToolsOutOfMemory.exitStatus). "
                + "The plan's clumpifyHeapGB sets that heap. The record keeps no payload."
        )
        XCTAssertEqual(step.storage?.launches?.map(\.tool.id), ["bgzip", "clumpify.sh"])
    }

    /// UX fix 1 of the K4 part C review (tally-r2 N3-2). A BBTools step whose probe finds no bgzip that answers
    /// `bgzip -h`, because the manifest lists none or the one it lists fails, fails before clumpify starts with the
    /// ruled sentence, so no node stores bytes from a writer the plan does not name. The run states the sentence alone.
    func testExecutorRefusesBBToolsStepWhenBgzipProbeFails() throws {
        for (label, bgzip, listed) in [("no bgzip listed", "[ \"$1\" = \"-h\" ]", false), ("bgzip exits 1", "exit 1", true)] {
            let (fixture, plan, manifest) = try clumpifyPlan("echo ran > logs/clumpify.ran", bgzip: bgzip, manifestListsBgzip: listed)
            let run = try fixture.run(plan, ["--image-manifest", manifest])
            XCTAssertEqual(run.status, ExecutorExitCode.failed, "\(label): \(run.stderr)")
            let record = try XCTUnwrap(run.record, label)
            XCTAssertEqual(record.outcome, .failed, label)
            XCTAssertEqual(record.failedStepID, "storage", label)
            XCTAssertEqual(record.searchPath, [fixture.toolsFolder, "/usr/bin", "/bin"], label)
            let sentence = "Step storage did not run. clumpify.sh compresses its output with bgzip, and no bgzip answered "
                + "`bgzip -h` on the step's PATH (\((record.searchPath ?? []).joined(separator: ":"))). The tool image must "
                + "hold bgzip beside the BBTools scripts."
            let step = try XCTUnwrap(record.steps.first, label)
            XCTAssertEqual(step.outcome, .failed, label)
            XCTAssertEqual(step.reason, sentence, label)
            XCTAssertEqual(record.reason, sentence, label)
            XCTAssertEqual(step.outputs, [], label)
            XCTAssertEqual(record.payloads, [], label)
            XCTAssertFalse(step.storage?.launches?.contains { $0.tool.id == "clumpify.sh" } ?? false, label)
            XCTAssertNil(step.storage?.writer, label)
            XCTAssertFalse(fixture.exists("logs/clumpify.ran"), "\(label): clumpify ran")
        }
    }

    /// QV-23. Each launch the storage step accepts records the files it read and wrote with their SHA-256, hashed
    /// before the step deletes a scratch file, and the writer probe, which reads and writes no file, records none.
    func testStorageLaunchesRecordTheirFilesWithDigests() throws {
        let (fixture, plan, manifest) = try clumpifyPlan("""
        for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        gzip -c < "$IN" > "$OUT"
        """)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let step = try XCTUnwrap(run.record?.steps.first)
        XCTAssertEqual(step.outcome, .succeeded, step.reason ?? "")
        let launches = try XCTUnwrap(step.storage?.launches)
        XCTAssertEqual(launches.map(\.tool.id), ["bgzip", "clumpify.sh"])
        XCTAssertNil(launches.first?.inputs)
        XCTAssertNil(launches.first?.outputs)
        let input = try Data(contentsOf: URL(fileURLWithPath: fixture.planFolder + "/inputs/R1.fastq"))
        XCTAssertEqual(launches.last?.inputs, [ExecutorFileDigest(
            relativePath: "inputs/R1.fastq", sha256: PortableDigest.sha256Hex(of: input), size: Int64(input.count)
        )])
        let payload = try XCTUnwrap(step.outputs.first)
        XCTAssertEqual(launches.last?.outputs?.map(\.sha256), [payload.sha256])
        XCTAssertEqual(launches.last?.outputs?.map(\.size), [Int64(payload.bytes)])
        XCTAssertEqual(launches.last?.outputs?.map(\.relativePath), ["out/sample.fastq.gz"])
    }

    /// CHTC CH-8 of vote C4-4. The storage step records the largest size its work root reached, from the executor's own
    /// walks while the step ran, so a scratch file the tool writes and deletes before it ends still counts, though the
    /// walks at the step's start and end never see it.
    func testStorageRecordsPeakWorkRootBytesOfAScratchFileItDeleted() throws {
        let scratchBytes = 8 * 1_048_576
        let (fixture, plan, manifest) = try clumpifyPlan("""
        for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
        head -c \(scratchBytes) /dev/zero > tmp/scratch.bin
        sleep 2
        rm tmp/scratch.bin
        gzip -c < "$IN" > "$OUT"
        """)
        let run = try fixture.run(plan, ["--image-manifest", manifest])
        XCTAssertEqual(run.status, ExecutorExitCode.succeeded, run.stderr)
        let step = try XCTUnwrap(run.record?.steps.first)
        XCTAssertEqual(step.outcome, .succeeded, step.reason ?? "")
        XCTAssertFalse(fixture.exists("tmp/scratch.bin"), "the stub removed its scratch file")
        let peak = try XCTUnwrap(step.storage?.peakWorkRootBytes)
        XCTAssertGreaterThanOrEqual(peak, UInt64(scratchBytes), "peakWorkRootBytes \(peak)")
        XCTAssertLessThan(WorkRootDiskSampler.bytes(under: fixture.planFolder), UInt64(scratchBytes), "the folder at the end")
    }

    /// The walk behind `peakWorkRootBytes` sums each regular file once by device and inode and follows no link.
    func testWorkRootWalkCountsAHardLinkOnceAndFollowsNoLink() throws {
        let root = try ExecutorTestSupport.scratchFolder()
        let outside = try ExecutorTestSupport.scratchFolder()
        try FileManager.default.createDirectory(atPath: root + "/work/deep", withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: URL(fileURLWithPath: root + "/work/deep/a.bin"))
        try Data(count: 24).write(to: URL(fileURLWithPath: root + "/b.txt"))
        try Data(count: 50_000).write(to: URL(fileURLWithPath: outside + "/big.bin"))
        try FileManager.default.linkItem(atPath: root + "/work/deep/a.bin", toPath: root + "/work/a-link.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/work/big.bin", withDestinationPath: outside + "/big.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/outside", withDestinationPath: outside)
        XCTAssertEqual(WorkRootDiskSampler.bytes(under: root), 1_024)
    }

    /// C4-3 C-4 (QA Q-4d). The record may name the writer's environment by the route that ran it, so the version is the
    /// one check left that the bgzip BBTools writes through is the one the plan pins. A probe whose answering bgzip
    /// states another version on its `Version:` line, or no version, fails the step before clumpify starts.
    func testStorageRefusesAnsweringBgzipOfAnotherVersion() throws {
        let cases = [
            ("version 1.23", "echo 'Version: 1.23'", "states version 1.23, not the version 1.0 the plan pins"),
            ("no version", "echo 'Usage: bgzip [OPTIONS] [FILE] ...'",
             "states no version, so the executor cannot tell it is the version 1.0 the plan pins"),
        ]
        for (label, help, states) in cases {
            let (fixture, plan, manifest) = try clumpifyPlan(
                "echo ran > logs/clumpify.ran", bgzip: "[ \"$1\" = \"-h\" ] && \(help)"
            )
            let run = try fixture.run(plan, ["--image-manifest", manifest])
            XCTAssertEqual(run.status, ExecutorExitCode.failed, "\(label): \(run.stderr)")
            let record = try XCTUnwrap(run.record, label)
            XCTAssertEqual(record.failedStepID, "storage", label)
            let bgzip = try XCTUnwrap(fixture.tools.first { $0.id == "bgzip" }, label)
            let sentence = "Step storage did not run. clumpify.sh compresses its output with bgzip, and the bgzip that "
                + "answered `bgzip -h` on the step's PATH, \(bgzip.path), \(states). The tool image must hold the pinned "
                + "bgzip beside the BBTools scripts."
            let step = try XCTUnwrap(record.steps.first, label)
            XCTAssertEqual(step.outcome, .failed, label)
            XCTAssertEqual(step.reason, sentence, label)
            XCTAssertEqual(record.reason, sentence, label)
            XCTAssertEqual(step.outputs, [], label)
            XCTAssertEqual(record.payloads, [], label)
            XCTAssertEqual(step.storage?.launches?.map(\.tool.id), ["bgzip"], label)
            XCTAssertNil(step.storage?.writer, label)
            XCTAssertFalse(fixture.exists("logs/clumpify.ran"), "\(label): clumpify ran")
        }
    }

    /// QA Fix 3 of the lane V review set 2 (Q-4d). The quantize-only route, storage route `none` with a binning scheme,
    /// probes the writer and requires the pinned bgzip version before `reformat.sh` writes a byte, the same refusal as
    /// the clumpify route. Without the call at its site, only the stub's moved `Version: 1.0` line kept the tests green.
    func testQuantizeStorageRefusesAnsweringBgzipOfAnotherVersion() throws {
        let cases = [
            ("version 1.23", "echo 'Version: 1.23'", "states version 1.23, not the version 1.0 the plan pins"),
            ("no version", "echo 'Usage: bgzip [OPTIONS] [FILE] ...'",
             "states no version, so the executor cannot tell it is the version 1.0 the plan pins"),
        ]
        for (label, help, states) in cases {
            var fixture = try RunPlanFixture()
            let reformat = try fixture.addTool("reformat.sh", """
            printf '%s\\n' "$@" > logs/reformat.argv
            for a in "$@"; do case "$a" in in=*) IN="${a#in=}" ;; out=*) OUT="${a#out=}" ;; esac; done
            gzip -c < "$IN" > "$OUT"
            """)
            let bgzip = try fixture.addTool("bgzip", "[ \"$1\" = \"-h\" ] && \(help)")
            let gzip = try fixture.addLoggingGzip()
            let manifest = try fixture.writeManifest()
            let settings = noneStorage(.illumina4)
            let step = PlanStep(
                id: "storage", title: "Store reads", kind: .storage, tool: reformat, arguments: [], deadlineSeconds: 60,
                inputs: ["inputs/R1.fastq"], outputs: ["out/sample.fastq.gz"]
            )
            let plan = try fixture.writePlan(
                [step], manifestPin: manifest.pin, storage: settings.storage, clumping: settings.clumping, pins: [bgzip, gzip]
            )
            let run = try fixture.run(plan, ["--image-manifest", manifest.path])
            XCTAssertEqual(run.status, ExecutorExitCode.failed, "\(label): \(run.stderr)")
            let record = try XCTUnwrap(run.record, label)
            XCTAssertEqual(record.failedStepID, "storage", label)
            let answering = try XCTUnwrap(fixture.tools.first { $0.id == "bgzip" }, label)
            let sentence = "Step storage did not run. reformat.sh compresses its output with bgzip, and the bgzip that "
                + "answered `bgzip -h` on the step's PATH, \(answering.path), \(states). The tool image must hold the pinned "
                + "bgzip beside the BBTools scripts."
            let stored = try XCTUnwrap(record.steps.first, label)
            XCTAssertEqual(stored.outcome, .failed, label)
            XCTAssertEqual(stored.reason, sentence, label)
            XCTAssertEqual(stored.outputs, [], label)
            XCTAssertEqual(record.payloads, [], label)
            XCTAssertFalse(fixture.exists("logs/reformat.argv"), "\(label): reformat.sh ran")
        }
    }
}
