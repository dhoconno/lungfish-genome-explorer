// ExecutionPlanTests.swift - The plan decoder's named refusals (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

final class ExecutionPlanTests: XCTestCase {
    private static let digest = String(repeating: "a", count: 64)
    private static let clumpify = PlanToolPin(id: "clumpify.sh", version: "40.02", build: "hdfd78af_0")
    private static let reformat = PlanToolPin(id: "reformat.sh", version: "40.02", build: "hdfd78af_0")
    private static let seqkit = PlanToolPin(id: "seqkit", version: "2.10.0", build: "h9ee0642_0")

    private func samplePlan(compressor: PlanCompressor = .bgzip, clumpingTool: PlanClumpingTool = .bbtools) -> ExecutionPlan {
        let digest = Self.digest
        return ExecutionPlan(
            entries: [
                PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: digest, size: 10),
                PlanEntry(role: .input, relativePath: "inputs/r1.fastq.gz", sha256: digest, size: 20),
                PlanEntry(role: .recipe, relativePath: "recipe/vsp2.json", sha256: digest, size: 30),
            ],
            executor: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "b481df34e2f6318af13f97349ff007241d7e2971",
                targetTriple: "x86_64-swift-linux-musl", toolchainID: "swift-6.2", toolchainSHA256: digest,
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: digest
            ),
            imageManifest: PlanImageManifestPin(sha256: digest, size: 512),
            tools: [Self.clumpify, Self.reformat, Self.seqkit],
            recipe: PlanRecipeIdentity(id: "vsp2", name: "VSP2", requestedName: "vsp2", formatVersion: 2, sourceSHA256: digest),
            sample: PlanSampleValues(sampleName: "S1", originalFilenames: ["S1_R1.fastq.gz"], originalSizeBytes: 20),
            storage: PlanStorageSettings(
                clumpingTool: clumpingTool, compressor: compressor, qualityBinning: .illumina4, threads: 4,
                clumpifyHeapGB: 8, compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .default,
                clumpingToolSource: .default, compressorSource: .default, qualityBinningSource: .default
            ),
            clumping: PlanClumpingChoice(
                requested: .auto, resolved: clumpingTool, resolvedSource: .default, heapBytes: 8 * 1_073_741_824,
                reason: "The plan writer's rule names BBTools clumpify at the plan's heap."
            ),
            graceSeconds: 30,
            steps: [
                PlanStep(
                    id: "storage", title: "Store reads", kind: .storage, tool: Self.clumpify,
                    arguments: ["in=inputs/r1.fastq.gz", "out=out/reads.fastq.gz"],
                    environment: [PlanEnvironmentVariable(name: "_JAVA_OPTIONS", value: "-Xmx8g")],
                    deadlineSeconds: 3600, inputs: ["inputs/r1.fastq.gz"], outputs: ["out/reads.fastq.gz"]
                ),
                PlanStep(
                    id: "stats", title: "Compute statistics", kind: .statistics, tool: Self.seqkit,
                    arguments: ["stats", "-a", "-T", "out/reads.fastq.gz"], deadlineSeconds: 600,
                    inputs: ["out/reads.fastq.gz"], outputs: [], standardOutput: "out/stats.tsv"
                ),
                PlanStep(
                    id: "q20", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
                    deadlineSeconds: 600, inputs: ["out/reads.fastq.gz"], outputs: []
                ),
            ]
        )
    }

    private func setValue(_ dictionary: inout [String: Any], _ path: ArraySlice<String>, _ value: Any?) {
        guard let key = path.first else { return }
        if path.count == 1 {
            dictionary[key] = value
            return
        }
        var child = dictionary[key] as? [String: Any] ?? [:]
        setValue(&child, path.dropFirst(), value)
        dictionary[key] = child
    }

    /// The sample plan's JSON with the value at `path` replaced, or removed when `value` is nil.
    private func planData(_ path: [String], _ value: Any?, plan: ExecutionPlan? = nil) throws -> Data {
        let data = try (plan ?? samplePlan()).encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        setValue(&object, path[...], value)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertRefused(
        _ data: Data, field: String, reason: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try ExecutionPlan.decode(data), file: file, line: line) { error in
            guard let refusal = error as? PlanDecodeError else {
                return XCTFail("Expected a PlanDecodeError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(refusal.field, field, file: file, line: line)
            if let reason { XCTAssertEqual(refusal.reason, reason, file: file, line: line) }
        }
    }

    func testValidPlanRoundTripsAndImageManifestIsNoEntryRole() throws {
        let plan = samplePlan()
        XCTAssertEqual(try ExecutionPlan.decode(plan.encoded()), plan)
        XCTAssertEqual(PlanEntryRole.allCases.map(\.rawValue), ["recipe", "database", "input", "executor"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.encoded()) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[1]["role"] = "imageManifest"
        object["entries"] = entries
        assertRefused(try JSONSerialization.data(withJSONObject: object), field: "entries[1].role")
    }

    /// One behaviour under the five names of tally K4.5: no `auto`, no missing value, no 0 for threads or heap.
    func testPlanDecodeRefusesAutoClumpingAndCompressor() throws {
        let autoTool = "This plan leaves the clumping tool as auto. A plan must name bbtools, trim-galore or none."
        let autoCompressor = "This plan leaves the compressor as auto. A plan must name pigz or bgzip."
        assertRefused(try planData(["storage", "clumpingTool"], "auto"), field: "storage.clumpingTool", reason: autoTool)
        assertRefused(try planData(["clumping", "resolved"], "auto"), field: "clumping.resolved", reason: autoTool)
        assertRefused(try planData(["storage", "compressor"], "auto"), field: "storage.compressor", reason: autoCompressor)
        assertRefused(
            try planData(["storage", "clumpingTool"], nil), field: "storage.clumpingTool",
            reason: "This plan names no clumping tool. A plan must name bbtools, trim-galore or none."
        )
        assertRefused(
            try planData(["storage", "compressor"], nil), field: "storage.compressor",
            reason: "This plan names no compressor. A plan must name pigz or bgzip."
        )
        for key in ["threads", "clumpifyHeapGB"] {
            assertRefused(try planData(["storage", key], 0), field: "storage.\(key)")
            assertRefused(try planData(["storage", key], -2), field: "storage.\(key)")
            assertRefused(try planData(["storage", key], nil), field: "storage.\(key)")
        }
        assertRefused(try planData(["storage", "qualityBinning"], nil), field: "storage.qualityBinning")
        assertRefused(try planData(["storage", "qualityBinning"], "auto"), field: "storage.qualityBinning")
        // BIO K4A fix 4. The plan states no statistics thread count, since `seqkit stats -a -T` takes none.
        XCTAssertNil(try (JSONSerialization.jsonObject(with: planData(["storage", "qualityBinning"], "none")) as? [String: Any])?["statistics"])
        XCTAssertNoThrow(try ExecutionPlan.decode(planData(["storage", "qualityBinning"], "none")))
    }

    func testPlanRefusesBBToolsStorageWithoutBgzip() throws {
        assertRefused(
            try samplePlan(compressor: .pigz).encoded(), field: "storage.compressor",
            reason: "This plan names pigz as the compressor for step storage, which runs clumpify.sh. BBTools compresses its output with bgzip, so the plan must name bgzip."
        )
        var binning = samplePlan(compressor: .pigz, clumpingTool: .none)
        binning.steps[0].tool = Self.reformat
        binning.steps[0].id = "bin-quality"
        assertRefused(
            try binning.encoded(), field: "storage.compressor",
            reason: "This plan names pigz as the compressor for step bin-quality, which runs reformat.sh. BBTools compresses its output with bgzip, so the plan must name bgzip."
        )
        binning.storage.compressor = .bgzip
        XCTAssertNoThrow(try ExecutionPlan.decode(binning.encoded()))

        var compressOnly = samplePlan(compressor: .pigz, clumpingTool: .none)
        let pigz = PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_1")
        compressOnly.tools.append(pigz)
        compressOnly.steps[0] = PlanStep(
            id: "compress", title: "Compress reads", kind: .compress, tool: pigz, arguments: ["-p", "4", "-c", "inputs/r1.fastq.gz"],
            deadlineSeconds: 600, inputs: ["inputs/r1.fastq.gz"], outputs: [], standardOutput: "out/reads.fastq.gz"
        )
        XCTAssertNoThrow(try ExecutionPlan.decode(compressOnly.encoded()))
    }

    func testPlanDecodeRefusesHostOrPlanAsValueSource() throws {
        for key in ["threadsSource", "clumpifyHeapSource", "clumpingToolSource", "compressorSource"] {
            for source in ["host", "plan", "recipe"] {
                assertRefused(try planData(["storage", key], source), field: "storage.\(key)")
            }
        }
        assertRefused(try planData(["storage", "qualityBinningSource"], "host"), field: "storage.qualityBinningSource")
        assertRefused(try planData(["storage", "qualityBinningSource"], "plan"), field: "storage.qualityBinningSource")
        XCTAssertNoThrow(try ExecutionPlan.decode(planData(["storage", "qualityBinningSource"], "recipe")))
        assertRefused(try planData(["clumping", "resolvedSource"], "option"), field: "clumping.resolvedSource")
        assertRefused(try planData(["clumping", "resolvedSource"], "plan"), field: "clumping.resolvedSource")
        var named = samplePlan(clumpingTool: .none)
        named.clumping.requested = .none
        named.clumping.resolvedSource = .option
        XCTAssertNoThrow(try ExecutionPlan.decode(named.encoded()))
        XCTAssertEqual(ImportSettingSource(rawValue: "plan"), .plan)
    }

    func testPlanRefusesUnpinnedToolReservedVariableAndEscapingStepPath() throws {
        var unpinned = samplePlan()
        unpinned.steps[1].tool = PlanToolPin(id: "seqkit", version: "2.9.0", build: "h9ee0642_0")
        assertRefused(try unpinned.encoded(), field: "steps[1].tool")
        var relativePath = samplePlan()
        relativePath.steps[0].environment.append(PlanEnvironmentVariable(name: "PATH", value: "bin:/opt/bin"))
        assertRefused(try relativePath.encoded(), field: "steps[0].environment[1]")
        var escaping = samplePlan()
        escaping.steps[0].outputs = ["../reads.fastq.gz"]
        assertRefused(try escaping.encoded(), field: "steps[0].outputs")
        var noDeadline = samplePlan()
        noDeadline.steps[2].deadlineSeconds = 0
        assertRefused(try noDeadline.encoded(), field: "steps[2].deadlineSeconds")
        var longGrace = samplePlan()
        longGrace.graceSeconds = 121
        assertRefused(try longGrace.encoded(), field: "graceSeconds")
    }

    /// SWIFT fix 2 of the K4 part A review: a deadline or heap whose product would trap the controller or the decoder is
    /// refused by its field, so the run ends with a named error and a record (tally K4.5).
    func testPlanDecodeRefusesNumbersThatWouldTrap() throws {
        var longDeadline = samplePlan()
        longDeadline.steps[0].deadlineSeconds = 1e300
        assertRefused(try longDeadline.encoded(), field: "steps[0].deadlineSeconds")
        var leapYear = samplePlan()
        leapYear.steps[0].deadlineSeconds = 31_622_400
        XCTAssertNoThrow(try ExecutionPlan.decode(leapYear.encoded()))
        leapYear.steps[0].deadlineSeconds = 31_622_401
        assertRefused(try leapYear.encoded(), field: "steps[0].deadlineSeconds")

        var atCap = samplePlan()
        atCap.storage.clumpifyHeapGB = 65_536
        atCap.clumping.heapBytes = 65_536 * 1_073_741_824
        XCTAssertNoThrow(try ExecutionPlan.decode(atCap.encoded()))
        atCap.storage.clumpifyHeapGB = 65_537
        atCap.clumping.heapBytes = 65_537 * 1_073_741_824
        assertRefused(try atCap.encoded(), field: "storage.clumpifyHeapGB")
        var hugeHeap = samplePlan()
        hugeHeap.storage.clumpifyHeapGB = 10_000_000_000
        assertRefused(try hugeHeap.encoded(), field: "storage.clumpifyHeapGB")
    }

    /// SWIFT fix 3 of the K4 part A review: a NUL byte in a step path or argument is refused, since the C string a tool
    /// or `openat` reads ends there, so `..\0/x` would name the parent folder.
    func testPlanDecodeRefusesNulInStepPathOrArgument() throws {
        var nulOutput = samplePlan()
        nulOutput.steps[0].standardOutput = "..\u{0}/x"
        assertRefused(try nulOutput.encoded(), field: "steps[0].standardOutput")
        var nulArgument = samplePlan()
        nulArgument.steps[0].arguments.append("out=out/reads.fastq.gz\u{0}--extra")
        assertRefused(try nulArgument.encoded(), field: "steps[0].arguments[2]")
    }
}
