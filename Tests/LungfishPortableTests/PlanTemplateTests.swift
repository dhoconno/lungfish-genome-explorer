// PlanTemplateTests.swift - The pure fill gives one sample's plan, with the same bytes on every platform (CHTC C4 lane F)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

final class PlanTemplateTests: XCTestCase {
    /// The SHA-256 of the plan `template()` gives for `sampleFill()`, recorded on the Mac (ARCH-fill F7). The Linux tier
    /// runs this test on glibc, so its pass there shows that a Linux caller of the fill gets the Mac's bytes.
    private static let filledSHA256 = "f7adab1de30120f17b14480ee3b6bf15342eed8d82f08596d31e34c98cdf0a7f"
    private static let digest = String(repeating: "a", count: 64)
    private static let clumpify = PlanToolPin(id: "clumpify.sh", version: "40.02", build: "hdfd78af_0")
    private static let reformat = PlanToolPin(id: "reformat.sh", version: "40.02", build: "hdfd78af_0")
    private static let seqkit = PlanToolPin(id: "seqkit", version: "2.10.0", build: "h9ee0642_0")
    private static let bgzip = PlanToolPin(id: "bgzip", version: "1.21", build: "h96c455f_0")

    /// A template made from plan types alone: an executor and a recipe entry, two gzip input slots, clumpify storage.
    private func template() -> PlanTemplate {
        let digest = Self.digest
        let inputs = ["inputs/R1.fastq.gz", "inputs/R2.fastq.gz"]
        return PlanTemplate(
            entries: [
                PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: digest, size: 10),
                PlanEntry(role: .recipe, relativePath: "recipe/vsp2.recipe.json", sha256: digest, size: 30),
            ],
            inputs: inputs.map { PlanInputSlot(relativePath: $0) },
            executor: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "b481df34e2f6318af13f97349ff007241d7e2971",
                targetTriple: "x86_64-swift-linux-musl", toolchainID: "swift-6.2", toolchainSHA256: digest,
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: digest
            ),
            imageManifest: PlanImageManifestPin(sha256: digest, size: 512),
            tools: [Self.clumpify, Self.reformat, Self.seqkit, Self.bgzip],
            recipe: PlanRecipeIdentity(id: "vsp2", name: "VSP2", requestedName: "vsp2", formatVersion: 2, sourceSHA256: digest),
            platform: "illumina",
            storage: PlanStorageSettings(
                clumpingTool: .bbtools, compressor: .bgzip, qualityBinning: .illumina4, threads: 4,
                clumpifyHeapGB: 8, compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .default,
                clumpingToolSource: .default, compressorSource: .default, qualityBinningSource: .default
            ),
            clumping: PlanClumpingChoice(
                requested: .auto, resolved: .bbtools, resolvedSource: .default, heapBytes: 8 * 1_073_741_824,
                reason: "The plan writer's rule names BBTools clumpify at the plan's heap."
            ),
            graceSeconds: 30,
            steps: [
                PlanStep(
                    id: "storage", title: "Store reads", kind: .storage, tool: Self.clumpify, arguments: [],
                    environment: [PlanEnvironmentVariable(name: "_JAVA_OPTIONS", value: "-Xmx8g")],
                    deadlineSeconds: 3600, inputs: inputs, outputs: ["out/sample.fastq.gz"]
                ),
                PlanStep(
                    id: "statistics", title: "Compute statistics", kind: .statistics, tool: Self.seqkit,
                    arguments: ["stats", "-a", "-T", "out/sample.fastq.gz"], deadlineSeconds: 600,
                    inputs: ["out/sample.fastq.gz"], outputs: [], standardOutput: "out/sample.seqkit-stats.tsv"
                ),
                PlanStep(
                    id: "quality-count", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
                    deadlineSeconds: 600, inputs: ["out/sample.fastq.gz"], outputs: []
                ),
            ]
        )
    }

    private func sampleFill() -> PlanSampleFill {
        PlanSampleFill(
            sampleName: "S1", originalFilenames: ["S1_R1.fastq.gz", "S1_R2.fastq.gz"],
            sampleSheet: [PlanKeyValue(key: "site", value: "Madison")],
            inputs: [
                PlanInputFile(sha256: String(repeating: "1", count: 64), size: 20),
                PlanInputFile(sha256: String(repeating: "2", count: 64), size: 22),
            ]
        )
    }

    /// ARCH-fill F7: a template built from plan types alone, filled with one sample, gives the bytes the Mac recorded.
    func testFillGivesTheSameBytesOnEveryPlatform() throws {
        let plan = try template().fill(sampleFill())
        XCTAssertEqual(plan.entries.map(\.relativePath), [
            "bin/lungfish-executor", "recipe/vsp2.recipe.json", "inputs/R1.fastq.gz", "inputs/R2.fastq.gz",
        ])
        XCTAssertEqual(plan.entries.filter { $0.role == .input }.map(\.sha256), sampleFill().inputs.map(\.sha256))
        XCTAssertEqual(plan.sample, PlanSampleValues(
            sampleName: "S1", originalFilenames: ["S1_R1.fastq.gz", "S1_R2.fastq.gz"], originalSizeBytes: 42,
            platform: "illumina", sampleSheet: [PlanKeyValue(key: "site", value: "Madison")]
        ))
        let bytes = try plan.encoded()
        XCTAssertEqual(try ExecutionPlan.decode(bytes), plan)
        XCTAssertEqual(PortableDigest.sha256Hex(of: bytes), Self.filledSHA256)
    }

    /// ARCH-fill F4: the fill refuses a sample with another number of inputs, or a file whose suffix is not its slot's,
    /// naming the field, and a plan the decoder refuses keeps the decoder's own error.
    func testFillRefusesASampleTheTemplateDoesNotHold() {
        var single = sampleFill()
        single.inputs.removeLast()
        XCTAssertThrowsError(try template().fill(single)) { error in
            XCTAssertEqual(error as? PlanFillRefusal, PlanFillRefusal(
                field: "entries", reason: "This template reads 2 input files, and the sample gives 1."
            ))
        }

        var renamed = sampleFill()
        renamed.originalFilenames[1] = "S1_R2.fq.gz"
        XCTAssertThrowsError(try template().fill(renamed)) { error in
            XCTAssertEqual(error as? PlanFillRefusal, PlanFillRefusal(
                field: "sample.originalFilenames",
                reason: "The file S1_R2.fq.gz takes the suffix .fq.gz, and this template's input inputs/R2.fastq.gz takes .fastq.gz. A sample whose files take another suffix needs a template of its own."
            ))
        }

        var unnamed = sampleFill()
        unnamed.originalFilenames.removeLast()
        XCTAssertThrowsError(try template().fill(unnamed)) { error in
            XCTAssertEqual((error as? PlanFillRefusal)?.field, "sample.originalFilenames")
        }

        var pigz = template()
        pigz.storage.compressor = .pigz
        XCTAssertThrowsError(try pigz.fill(sampleFill())) { error in
            XCTAssertNotNil(error as? PlanDecodeError, "\(error)")
        }
    }

    /// The fill reads the suffix rule the Mac's emitter names each slot with.
    func testFastqSuffixKeepsTheCompressionOfTheName() {
        XCTAssertEqual(PlanTemplate.fastqSuffix(of: "S_R1.FASTQ.GZ"), ".fastq.gz")
        XCTAssertEqual(PlanTemplate.fastqSuffix(of: "S_R1.fq.gz"), ".fq.gz")
        XCTAssertEqual(PlanTemplate.fastqSuffix(of: "S_R1.fq"), ".fq")
        XCTAssertEqual(PlanTemplate.fastqSuffix(of: "reads"), ".fastq")
    }
}
