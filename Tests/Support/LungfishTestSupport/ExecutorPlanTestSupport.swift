// ExecutorPlanTestSupport.swift - A plan request and a returned plan folder for the plan and adopt tests (CHTC C4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The plan emitter's tests, the adopt's tests and the CLI's process tests of `import fastq --adopt` build their plans
// and returned folders here, so a process test can hand the built CLI the same folder the in-process tests adopt.

import Foundation
import LungfishPortable
import LungfishWorkflow

/// The request a plan test hands the emitter: no database, threads 1, a 4 GB heap, illumina4, an executor stand-in.
package enum ExecutorPlanTestSupport {
    package static let digest = String(repeating: "b", count: 64)
    package static let mac24 = ExecutorPlanHostFacts(physicalMemoryBytes: 24 * 1_073_741_824, processorCount: 4)
    package static let pins = [
        PlanToolPin(id: "fastp", version: "1.0.1", build: "h43da1c4_0"),
        PlanToolPin(id: "clumpify.sh", version: "39.13", build: "he5f24ec_0"),
        PlanToolPin(id: "reformat.sh", version: "39.13", build: "he5f24ec_0"),
        PlanToolPin(id: "seqkit", version: "2.10.0", build: "h9ee0642_0"),
        PlanToolPin(id: "gzip", version: "1.13", build: "h8359307_0"),
        PlanToolPin(id: "bgzip", version: "1.21", build: "h3ff9d97_0"),
        PlanToolPin(id: "java", version: "25.0.2", build: "h1602c4f_26"),
        PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_1"),
        PlanToolPin(id: "deacon", version: "0.13.2", build: "h4349ce8_0"),
        PlanToolPin(id: "trim_galore", version: "2.3.0", build: "h48b4a6d_0"),
    ]

    /// A small R1/R2 pair named for `sample` in its own folder under `root`.
    package static func writePair(root: URL, _ sample: String) throws -> [URL] {
        let folder = root.appendingPathComponent(sample, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r1 = folder.appendingPathComponent("\(sample)_R1.fastq")
        let r2 = folder.appendingPathComponent("\(sample)_R2.fastq")
        try "@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair2/1\nTTGGCCAATT\n+\nIIIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n@pair2/2\nAATTGGCCAA\n+\nIIIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        return [r1, r2]
    }

    /// A stand-in for a recipe's file, which a plan pins as its `recipe` entry.
    package static func recipeSource(root: URL) throws -> ExecutorPlanSourceFile {
        let file = root.appendingPathComponent("recipe-source.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data("{\"recipe\":\"stand-in\"}\n".utf8).write(to: file)
        }
        return try ExecutorPlanSourceFile.measuring(file)
    }

    package static func request(
        root: URL, _ sample: String, inputs: [URL], clumping: ClumpingTool, compressor: PlanCompressor = .bgzip,
        recipe: Recipe? = nil
    ) throws -> ExecutorPlanRequest {
        let executor = root.appendingPathComponent("lungfish-executor")
        if !FileManager.default.fileExists(atPath: executor.path) {
            try Data("executor stand-in".utf8).write(to: executor)
        }
        let files = try inputs.map { try ExecutorPlanSourceFile.measuring($0) }
        return ExecutorPlanRequest(
            sample: PlanSampleValues(sampleName: sample, originalFilenames: inputs.map(\.lastPathComponent),
                                     originalSizeBytes: files.reduce(0) { $0 + $1.size }),
            inputs: files, inputFormat: .pairedR1R2, recipe: recipe,
            recipeFile: try recipe.map { _ in try recipeSource(root: root) },
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: clumping, clumpifyHeapGB: 4, threads: 1,
                compressor: compressor, qualityBinning: .illumina4, compressionLevel: 4, threadsSource: .option,
                clumpifyHeapSource: .option, compressorSource: .default, qualityBinningSource: .default
            ),
            executorFile: try ExecutorPlanSourceFile.measuring(executor),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "74ae0db3400d6b7519550e33dafc369e081fa114",
                targetTriple: "x86_64-swift-linux-musl", toolchainID: "swift-6.2", toolchainSHA256: digest,
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: digest
            ),
            imageManifest: PlanImageManifestPin(sha256: digest, size: 4096), imageTools: pins,
            deadlines: ExecutorPlanDeadlines(recipeStepSeconds: 3600, storageSeconds: 7200, statisticsSeconds: 1800, graceSeconds: 30)
        )
    }
}

/// A returned plan folder: the emitter's plan for sample `S`, a payload and a succeeded run record that is true to both.
package struct ExecutorReturnedFolder {
    package let folder: URL
    package let plan: ExecutionPlan
    package var record: ExecutorRunRecord

    /// The `seqkit stats -a -T` table for the payload's two 10-base reads, half G and C, with seqkit's whole percents.
    package static let seqkitTable = "file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\tQ1\tQ2\tQ3\tsum_gap\tN50\tN50_num\tQ20(%)\tQ30(%)\tAvgQual\tGC(%)\tsum_n\n"
        + "out/S.fastq.gz\tFASTQ\tDNA\t2\t20\t10\t10.0\t10\t10\t10\t10\t0\t10\t1\t95.00\t91.00\t40.00\t50.00\t0\n"

    package static var seqkitOutput: ExecutorCapturedOutput {
        ExecutorCapturedOutput(
            text: seqkitTable, sha256: PortableDigest.sha256Hex(of: Data(seqkitTable.utf8)), size: Int64(seqkitTable.utf8.count)
        )
    }

    /// Writes the record into the folder, after a test changed it.
    package func write() throws {
        try record.encoded().write(to: folder.appendingPathComponent(ExecutorRunRecord.fileName))
    }

    /// Emits the plan of a small pair under `root`, writes its folder as `returned-<clumping>` with a two-read payload,
    /// and writes a succeeded record whose every step ran the plan's argv.
    package static func make(root: URL, clumping: ClumpingTool, siteFacts: [PlanKeyValue] = []) throws -> ExecutorReturnedFolder {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emission = try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: clumping), host: ExecutorPlanTestSupport.mac24
        )
        let folder = root.appendingPathComponent("returned-\(clumping.rawValue)", isDirectory: true)
        let planFile = try ExecutorPlanFolderWriter.write(emission, into: folder)
        let planBytes = try Data(contentsOf: planFile)
        let payloadBytes = Data("@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n".utf8)
        let payloadURL = folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payloadBytes.write(to: payloadURL)
        let payload = ExecutorFileDigest(
            relativePath: ExecutorPlanEmitter.payloadPath, sha256: PortableDigest.sha256Hex(of: payloadBytes),
            size: Int64(payloadBytes.count)
        )
        let plan = emission.plan
        let time = "2026-10-24T12:00:00.000Z"
        let steps = plan.steps.map { step in
            var recorded = ExecutorStepRecord(
                id: step.id, kind: step.kind,
                tool: step.tool.map { ExecutorToolRecord(id: $0.id, version: $0.version, build: $0.build, path: "/opt/conda/bin/\($0.id)") },
                outcome: .succeeded, argv: step.arguments, environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30,
                deadlineSeconds: step.deadlineSeconds, toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 1,
                qualityCounts: step.kind == .qualityCount
                    ? ExecutorQualityCounts(baseCount: 20, q20Count: 20, q30Count: 20, recordCount: 2, file: payload) : nil,
                storage: step.kind == .storage
                    ? ExecutorStorageDetails(clumpingRan: plan.clumping.resolved == .bbtools, qualityBinning: plan.storage.qualityBinning,
                                             inputBytes: 200, outputBytes: payload.size)
                    : nil
            )
            if step.kind == .statistics {
                recorded.standardOutput = seqkitOutput
                // The executor records the file seqkit read, the payload (AMV1 BIO fix 2).
                recorded.inputFile = payload
            }
            return recorded
        }
        let record = ExecutorRunRecord(
            outcome: .succeeded, executorArguments: ["run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: ExecutorPlanTestSupport.digest, size: 17, buildPin: plan.executor),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)),
            recipe: plan.recipe,
            imageManifest: ExecutorImageManifestRecord(sha256: plan.imageManifest.sha256, size: plan.imageManifest.size, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2, observedLimits: [],
                subreaper: ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "0", getterResult: 0, getterValue: 1),
                orphanSweep: .subreaper
            ),
            siteFacts: siteFacts, inputs: plan.entries.filter { $0.role != .executor },
            payloads: [ExecutorPayloadRecord(
                relativePath: payload.relativePath, sha256: payload.sha256, size: payload.size, recordCount: 2, recordCountFile: payload
            )],
            steps: steps, startedAt: time, endedAt: time, wallSeconds: 3
        )
        let returned = ExecutorReturnedFolder(folder: folder, plan: plan, record: record)
        try returned.write()
        return returned
    }
}
