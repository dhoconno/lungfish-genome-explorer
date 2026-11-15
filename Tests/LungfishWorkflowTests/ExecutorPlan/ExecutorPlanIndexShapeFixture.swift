// ExecutorPlanIndexShapeFixture.swift - A stand-in schema 2 plan of an index build's shape (Phase 5.3 lane EX-SUBMIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
@testable import LungfishWorkflow

/// A schema 2 plan with no `input` entry and no `sample`, as the plans of an index build are: a `reference` entry, a
/// supplied list of sequence names, one `home` output and one `staged` output. Its two steps run `seqkit` and `pigz`,
/// two tools the pinned image's manifest lists. The batch of it holds a DAG node that reads no reads.
enum ExecutorPlanIndexShapeFixture {
    static let setID = "stand-in-set-0001"
    static let referencePath = "references/\(setID)/genome/ref.fa"
    static let listPath = "barcodes/ids.txt"
    static let homeOutput = "out/picked.fa"
    static let stagedOutput = "index/ref.fa.gz"
    static let referenceText = ">seq1\nACGTACGTAC\n>seq2\nTTTTGGGGCC\n>seq3\nCCAATTGGAA\n"
    static let listText = "seq2\n"
    /// The submit values of the stand-in's rule: 2048 MiB of memory, 1 CPU and 2 GiB of disk.
    static let memoryMiB: Int64 = 2048

    /// A file the plan pins, with the digest and size its entry holds.
    struct Source {
        var url: URL
        var sha256: String
        var size: Int64

        init(_ url: URL) throws {
            self.url = url
            sha256 = try PortableDigest.sha256Hex(ofFileAt: url)
            size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// The one job of the batch, named `sample`, with the plan and the Mac file of each entry a folder copies.
    static func job(
        sample: String = "index", executor: Source, reference: Source, list: Source, seqkit: PlanToolPin, pigz: PlanToolPin,
        imageManifest: PlanImageManifestPin
    ) -> ExecutorPlanBatchJob {
        let zeros = String(repeating: "0", count: 64)
        let entries = [
            PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: executor.sha256, size: executor.size),
            PlanEntry(role: .reference, relativePath: referencePath, sha256: reference.sha256, size: reference.size,
                      reference: PlanReferenceIdentity(setID: setID, path: "genome/ref.fa")),
            PlanEntry(role: .barcodeList, relativePath: listPath, sha256: list.sha256, size: list.size,
                      barcodeList: PlanBarcodeListIdentity(name: "stand-in-list", source: .supplied)),
        ]
        let plan = ExecutionPlan(
            entries: entries,
            executor: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros
            ),
            imageManifest: imageManifest, tools: [pigz, seqkit], recipe: nil,
            pipeline: PlanPipeline(
                id: "stand-in-index", version: 1, preset: PlanPipelinePreset(id: "stand-in", name: "Stand-in index"),
                modality: nil, route: nil, referenceSet: PlanPipelineReferenceSet(id: setID, layout: .lge), settings: []
            ),
            sample: nil, storage: nil, clumping: nil, graceSeconds: 5,
            steps: [
                PlanStep(id: "pick", title: "Pick the listed sequences", kind: .tool, tool: seqkit,
                         arguments: ["grep", "-f", listPath, "-o", homeOutput, referencePath], deadlineSeconds: 600,
                         inputs: [referencePath, listPath], outputs: [homeOutput], outputPolicy: [homeOutput: .home]),
                PlanStep(id: "pack", title: "Compress the reference", kind: .tool, tool: pigz,
                         arguments: ["-c", "-p", "1", referencePath], deadlineSeconds: 600, inputs: [referencePath],
                         outputs: [stagedOutput], standardOutput: stagedOutput, outputPolicy: [stagedOutput: .staged]),
            ]
        )
        let sources = ["bin/lungfish-executor": executor.url, referencePath: reference.url]
        return ExecutorPlanBatchJob(
            emission: ExecutorPlanEmission(plan: plan, sources: sources),
            submit: ExecutorPlanSubmitValues(sampleName: sample, requestDiskGiB: 2, requestMemoryMiB: memoryMiB, requestCpus: 1)
        )
    }
}
