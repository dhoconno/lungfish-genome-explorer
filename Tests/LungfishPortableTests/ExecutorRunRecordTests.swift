// ExecutorRunRecordTests.swift - The run record round-trips and an older record still opens (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

final class ExecutorRunRecordTests: XCTestCase {
    private static let digest = String(repeating: "b", count: 64)
    private static let k4Keys = ["writer", "effectiveCompressionLevel", "clumpifyGroups", "clumpifyMemoryEstimateLine", "clumpifyMemoryAvailableLine"]

    private func fullRecord() -> ExecutorRunRecord {
        let digest = Self.digest
        let clumpify = ExecutorToolRecord(id: "clumpify.sh", version: "40.02", build: "hdfd78af_0", path: "/opt/conda/envs/bbtools/bin/clumpify.sh")
        let bgzip = ExecutorToolRecord(id: "bgzip", version: "1.21", build: "h96c455f_0", path: "/opt/conda/envs/htslib/bin/bgzip")
        let reads = ExecutorFileDigest(relativePath: "out/reads.fastq.gz", sha256: digest, size: 4_096)
        let subreaper = ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "OK", getterResult: 0, getterValue: 1)
        return ExecutorRunRecord(
            outcome: .succeeded,
            executorArguments: ["lungfish-executor", "run", "--plan", "plan.json", "--site-fact", "Machine=e1.chtc.wisc.edu"],
            executor: ExecutorBinaryIdentity(
                sha256: digest, size: 52_000_000,
                buildPin: PlanExecutorBuild(
                    lgeVersion: "2026.10.22", lgeCommit: "74ae0db3400d6b7519550e33dafc369e081fa114",
                    targetTriple: "x86_64-swift-linux-musl", toolchainID: "swift-6.2", toolchainSHA256: digest,
                    staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: digest
                )
            ),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: digest, size: 9_000),
            imageManifest: ExecutorImageManifestRecord(sha256: digest, size: 2_048, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2,
                observedLimits: [
                    ExecutorObservedLimit(name: "memTotalBytes", value: "540000000000", source: "/proc/meminfo MemTotal"),
                    ExecutorObservedLimit(name: "cgroupMemoryMaxBytes", value: nil, source: "/sys/fs/cgroup memory.max"),
                ],
                subreaper: subreaper, orphanSweep: .subreaper
            ),
            siteFacts: [PlanKeyValue(key: "Machine", value: "e1.chtc.wisc.edu")],
            inputs: [PlanEntry(role: .input, relativePath: "inputs/r1.fastq.gz", sha256: digest, size: 20)],
            payloads: [ExecutorPayloadRecord(relativePath: reads.relativePath, sha256: digest, size: 4_096, recordCount: 1_000, recordCountFile: reads)],
            steps: [
                ExecutorStepRecord(
                    id: "storage", kind: .storage, tool: clumpify, outcome: .succeeded,
                    argv: [clumpify.path, "in=inputs/r1.fastq.gz", "out=out/reads.fastq.gz", "groups=auto"],
                    environmentNames: ["HOME", "PATH", "TMPDIR", "_JAVA_OPTIONS"], graceSeconds: 30, deadlineSeconds: 3_600,
                    toolPID: 41, toolExitCode: 0, peakResidentBytes: 3_000_000_000, startedAt: "2026-10-23T14:00:00.000Z",
                    endedAt: "2026-10-23T14:01:00.000Z", wallSeconds: 60,
                    outputs: [ExecutorStepRecord.Output(path: reads.relativePath, bytes: 4_096, sha256: digest)],
                    stderrTail: "Set groups to 3\n", stderrBytes: 16,
                    storage: ExecutorStorageDetails(
                        writer: ExecutorStorageWriter(name: "bgzip", tool: bgzip), effectiveCompressionLevel: 4,
                        clumpifyGroups: 3, clumpifyMemoryEstimateLine: "Memory Estimate:        2510 MB",
                        clumpifyMemoryAvailableLine: "Memory Available:       3276 MB", clumpingRan: true,
                        qualityBinning: .illumina4, inputBytes: 20, outputBytes: 4_096,
                        mixedLayout: ExecutorMixedLayoutCounts(mergedReads: 600, pairs: 200, unpairedReads: 0)
                    )
                ),
                ExecutorStepRecord(
                    id: "stats", kind: .statistics,
                    tool: ExecutorToolRecord(id: "seqkit", version: "2.10.0", build: "h9ee0642_0", path: "/opt/conda/envs/seqkit/bin/seqkit"),
                    outcome: .succeeded, argv: ["/opt/conda/envs/seqkit/bin/seqkit", "stats", "-a", "-T", reads.relativePath],
                    environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30, deadlineSeconds: 600,
                    startedAt: "2026-10-23T14:01:00.000Z", endedAt: "2026-10-23T14:01:02.000Z", wallSeconds: 2,
                    stderrTail: String(repeating: "x", count: 8), stderrTruncated: true, stderrBytes: 5_000_000,
                    standardOutput: ExecutorCapturedOutput(text: "file\tformat\nout/reads.fastq.gz\tFASTQ\n", sha256: digest, size: 37)
                ),
                ExecutorStepRecord(
                    id: "q20", kind: .qualityCount, tool: nil, outcome: .succeeded, argv: [], environmentNames: [],
                    graceSeconds: 30, deadlineSeconds: 600, startedAt: "2026-10-23T14:01:02.000Z",
                    endedAt: "2026-10-23T14:01:03.000Z", wallSeconds: 1,
                    qualityCounts: ExecutorQualityCounts(baseCount: 150_000, q20Count: 140_000, q30Count: 120_000, recordCount: 1_000, file: reads)
                ),
            ],
            startedAt: "2026-10-23T14:00:00.000Z", endedAt: "2026-10-23T14:01:03.000Z", wallSeconds: 63
        )
    }

    func testRunRecordRoundTripsAndOldRecordOpens() throws {
        let record = fullRecord()
        XCTAssertEqual(record.exitCode, ExecutorExitCode.succeeded)
        let bytes = try record.encoded()
        XCTAssertEqual(try ExecutorRunRecord.decode(bytes), record)
        XCTAssertEqual(try ExecutorRunRecord.decode(bytes).encoded(), bytes, "equal records must be equal bytes")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\\/"), "paths must not be escaped")

        // A record written before K4-14 has no writer, level, groups or memory lines as keys at all, and opens with
        // each absent, which the adopt shows as Not recorded.
        var expected = record
        expected.steps[0].storage = ExecutorStorageDetails(
            clumpingRan: true, qualityBinning: .illumina4, inputBytes: 20, outputBytes: 4_096,
            mixedLayout: ExecutorMixedLayoutCounts(mergedReads: 600, pairs: 200, unpairedReads: 0)
        )
        let oldText = String(decoding: try expected.encoded(), as: UTF8.self)
        for key in Self.k4Keys { XCTAssertFalse(oldText.contains("\"\(key)\""), "\(key) must be absent from the old record") }
        let old = try ExecutorRunRecord.decode(Data(oldText.utf8))
        let storage = try XCTUnwrap(old.steps[0].storage)
        XCTAssertNil(storage.writer)
        XCTAssertNil(storage.effectiveCompressionLevel)
        XCTAssertNil(storage.clumpifyGroups)
        XCTAssertNil(storage.clumpifyMemoryEstimateLine)
        XCTAssertNil(storage.clumpifyMemoryAvailableLine)
        XCTAssertEqual(old, expected)
        XCTAssertEqual(old.steps[1], record.steps[1], "the other steps open unchanged")

        // A refused run holds no plan, manifest or step, names its field and keeps the refused exit code.
        let refused = ExecutorRunRecord(
            outcome: .refused, reason: "The plan pins a different tool manifest.", refusedField: "imageManifest",
            executorArguments: ["lungfish-executor", "run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: nil, size: nil, buildPin: nil), plan: nil, imageManifest: nil,
            runtimeIdentity: record.runtimeIdentity, startedAt: "2026-10-23T14:00:00.000Z",
            endedAt: "2026-10-23T14:00:00.001Z", wallSeconds: 0.001
        )
        XCTAssertEqual(refused.exitCode, ExecutorExitCode.refused)
        XCTAssertEqual(try ExecutorRunRecord.decode(refused.encoded()), refused)
        XCTAssertEqual(ExecutorExitCode.outcome(for: ExecutorExitCode.interrupted), .interrupted)
        XCTAssertNil(ExecutorExitCode.outcome(for: ExecutorExitCode.usage))

        // A newer schema and an exit code that contradicts the outcome are refused by name.
        var newer = record
        newer.schemaVersion = ExecutorRunRecord.currentSchemaVersion + 1
        XCTAssertThrowsError(try ExecutorRunRecord.decode(newer.encoded())) { error in
            XCTAssertEqual((error as? ExecutorRunRecordDecodeError)?.field, "schemaVersion")
        }
        var contradicting = record
        contradicting.exitCode = ExecutorExitCode.failed
        XCTAssertThrowsError(try ExecutorRunRecord.decode(contradicting.encoded())) { error in
            XCTAssertEqual((error as? ExecutorRunRecordDecodeError)?.field, "exitCode")
        }
        XCTAssertEqual(ExecutorRunRecord.timestamp(Date(timeIntervalSince1970: 0.25)), "1970-01-01T00:00:00.250Z")
    }
}
