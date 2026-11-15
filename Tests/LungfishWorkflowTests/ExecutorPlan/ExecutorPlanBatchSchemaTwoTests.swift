// ExecutorPlanBatchSchemaTwoTests.swift - The CHTC submit side of a schema 2 plan (Phase 5.3 lane EX-SUBMIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// Ruling ARCH-SCHEMA-SPIKE section A. A stand-in schema 2 plan, built as EX-TOOL's folder writer test builds one, with a
/// `reference`, a supplied list, an image list, one `home`, one `staged` and one `stays` output, goes through the one
/// batch path of `import fastq --write-plan` with the submit values its emitter's rule gives.
final class ExecutorPlanBatchSchemaTwoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanBatchSchemaTwo")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private static let set = "stand-in-set-0001"
    private static let staging = "/staging/groups/g/1/lge-chtc-test"
    private let layout = ExecutorPlanStagingLayout(folder: staging, batch: "batch")
    private let image = ExecutorPlanImageRecord(
        sif: ExecutorPlanImageFile(fileName: "lge-tools-eae819829358.sif", sha256: String(repeating: "e", count: 64), size: 396_402_688),
        imageManifest: PlanImageManifestPin(sha256: ExecutorPlanTestSupport.digest, size: 4096)
    )

    private func file(_ name: String, _ text: String) throws -> (url: URL, sha256: String, size: Int64) {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return (url, PortableDigest.sha256Hex(of: Data(text.utf8)), Int64(text.utf8.count))
    }

    /// The stand-in plan of one sample and the Mac file of each entry a folder copies.
    private func emission(_ sample: String = "S") throws -> ExecutorPlanEmission {
        let executor = try file("lungfish-executor", "executor stand-in")
        let reads = try file("\(sample)_R1.fastq", "@r\nACGT\n+\nIIII\n")
        let fasta = try file("transcripts.fa", ">t\nA\n")
        let list = PortableDigest.sha256Hex(of: Data("AAACCCAAGAAACACT\n".utf8))
        let tool = PlanToolPin(id: "quant", version: "1.0", build: "t0")
        let settings = ["duplicates": "Duplicates: kept. LGE removes duplicates only with UMIs.", "trimming": "Reads not trimmed"]
        let referencePath = "references/\(Self.set)/derived/transcripts.fa"
        let plan = ExecutionPlan(
            entries: [
                PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: executor.sha256, size: executor.size),
                PlanEntry(role: .input, relativePath: "inputs/R1.fastq", sha256: reads.sha256, size: reads.size),
                PlanEntry(role: .reference, relativePath: referencePath, sha256: fasta.sha256, size: fasta.size,
                          reference: PlanReferenceIdentity(setID: Self.set, path: "derived/transcripts.fa")),
                PlanEntry(role: .barcodeList, relativePath: "barcodes/image.txt", sha256: list, size: 17,
                          barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: .image)),
                PlanEntry(role: .barcodeList, relativePath: "barcodes/mine.txt", sha256: list, size: 17,
                          barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: .supplied)),
            ],
            executor: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: ExecutorPlanTestSupport.digest, staticLinuxSDKID: "test",
                staticLinuxSDKSHA256: ExecutorPlanTestSupport.digest
            ),
            imageManifest: image.imageManifest, tools: [tool], recipe: nil,
            pipeline: PlanPipeline(
                id: "stand-in", version: 1, preset: PlanPipelinePreset(id: "bulk", name: "Stand-in"), modality: .bulk,
                route: PlanPipelineRoute(id: "stand-in", tool: "quant", toolVersion: "1.0", settings: settings),
                referenceSet: PlanPipelineReferenceSet(id: Self.set, layout: .lge),
                settings: settings.keys.sorted().map { PlanPipelineSetting(id: $0, label: $0, value: settings[$0] ?? "", source: .default) }
            ),
            sample: PlanSampleValues(sampleName: sample, originalFilenames: ["\(sample)_R1.fastq"], originalSizeBytes: reads.size),
            storage: nil, clumping: nil, graceSeconds: 5,
            steps: [PlanStep(
                id: "quant", title: "Count", kind: .tool, tool: tool, arguments: [referencePath, "barcodes/mine.txt", "inputs/R1.fastq"],
                deadlineSeconds: 60, inputs: ["inputs/R1.fastq"], outputs: ["out/quant.sf", "index/ref.idx", "out/reads.bam"],
                outputPolicy: ["out/quant.sf": .home, "index/ref.idx": .staged, "out/reads.bam": .stays]
            )]
        )
        let sources = ["bin/lungfish-executor": executor.url, "inputs/R1.fastq": reads.url, referencePath: fasta.url]
        return ExecutorPlanEmission(plan: plan, sources: sources)
    }

    private func job(_ sample: String = "S", memory: Int64? = 40_960, cpus: Int? = 8, disk: Int? = 30) throws -> ExecutorPlanBatchJob {
        ExecutorPlanBatchJob(
            emission: try emission(sample),
            submit: ExecutorPlanSubmitValues(sampleName: sample, requestDiskGiB: disk, requestMemoryMiB: memory, requestCpus: cpus)
        )
    }

    private func text(_ folder: URL, _ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func value(of command: String, in submit: String) throws -> String {
        let lines = submit.split(separator: "\n").filter { $0.hasPrefix("\(command) = ") }
        XCTAssertEqual(lines.count, 1, command)
        return String(try XCTUnwrap(lines.first).dropFirst(command.count + 3))
    }

    /// Items 2 to 4 of the ruling's brief. The batch places the executor, the reference and the supplied list, then the
    /// read, and never the image's list. It returns the record, the logs and the `home` output, remaps the `staged`
    /// output to `staged/` and leaves the `stays` output, and each job asks the memory, CPUs and disk it was given.
    func testSchemaTwoBatchPlacesByRoleReturnsHomeAndRemapsStaged() throws {
        let job = try job()
        let plan = job.emission.plan
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write([job], image: image, layout: layout, into: folder)
        let shared = "\(Self.staging)/shared"
        let executor = "\(plan.entries[0].sha256)-lungfish-executor"
        let reference = "\(plan.entries[2].sha256)-transcripts.fa"
        let list = "\(plan.entries[4].sha256)-mine.txt"

        let jobs = try text(folder, "jobs.tsv").split(separator: "\n").map(String.init)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(Array(jobs[1].split(separator: "\t").dropFirst(3)), [
            "shared/\(executor)=bin/lungfish-executor", "shared/\(reference)=references/\(Self.set)/derived/transcripts.fa",
            "shared/\(list)=barcodes/mine.txt", "batches/batch/S/R1.fastq=inputs/R1.fastq",
        ])
        let submit = try text(folder, "sample.sub")
        XCTAssertFalse(submit.contains("image.txt"), submit)
        XCTAssertTrue(try value(of: "arguments", in: submit).hasPrefix(
            "\"'\(executor)=bin/lungfish-executor' '\(reference)=references/\(Self.set)/derived/transcripts.fa' '\(list)=barcodes/mine.txt' $(sample_placements) '--' "
        ), submit)
        XCTAssertEqual(try value(of: "transfer_input_files", in: submit),
                       "$(sample_inputs), file://\(shared)/\(executor), file://\(shared)/\(reference), file://\(shared)/\(list)")
        XCTAssertEqual(try value(of: "transfer_output_files", in: submit),
                       "plan/run-record.json, plan/logs, plan/out/quant.sf, plan/index/ref.idx")
        let sample = "file://\(Self.staging)/batches/batch/$(sample)"
        XCTAssertEqual(try value(of: "transfer_output_remaps", in: submit), "\"" + [
            "plan/run-record.json = \(sample)/result/run-record.json", "plan/out/quant.sf = \(sample)/result/out/quant.sf",
            "plan/index/ref.idx = \(sample)/staged/index/ref.idx",
        ].joined(separator: "; ") + "\"")
        XCTAssertEqual(try value(of: "request_cpus", in: submit), "$(request_cpus)")
        XCTAssertEqual(try value(of: "request_memory", in: submit), "$(request_memory)")
        XCTAssertEqual(try value(of: "request_disk", in: submit), "$(request_disk)")

        let dag = try text(folder, "run.dag").split(separator: "\n").map(String.init)
        let vars = try XCTUnwrap(dag.first { $0.hasPrefix("VARS S ") })
        for pair in ["request_disk=\"30GB\"", "request_memory=\"40960MB\"", "request_cpus=\"8\"",
                     "sample_inputs=\"plan.tar, file://\(Self.staging)/batches/batch/S/R1.fastq\""] {
            XCTAssertTrue(vars.contains(pair), "\(pair) in \(vars)")
        }
        let base = "\(Self.staging)/batches/batch/S"
        XCTAssertTrue(dag.contains("SCRIPT PRE S /bin/mkdir -p \(base)/result \(base)/result/out \(base)/staged \(base)/staged/index"), "\(dag)")
        XCTAssertEqual(batch.folders.map(\.role), ["result-folder", "result-folder", "staged-folder", "staged-folder"])

        XCTAssertEqual(batch.files.map(\.role), ["image", "executor", "reference", "barcodeList", "input"])
        XCTAssertNil(batch.files[3].source, "LGE never copies a list the person supplied")
        XCTAssertEqual(batch.files[3].stagingPath, "\(shared)/\(list)")
        XCTAssertEqual(batch.placements, ExecutorPlanFolderWriter.placements(of: plan, shared: true))
        XCTAssertEqual(batch.placements.count, 1)
        let tar = try DeterministicTarReader.entries(in: folder.appendingPathComponent("S/plan.tar"))
        XCTAssertEqual(tar["plan/plan.json"], try plan.encoded())
        XCTAssertNil(tar["plan/references/\(Self.set)/derived/transcripts.fa"])

        let run = try text(folder, "run-local.sh")
        XCTAssertTrue(run.contains("for path in run-record.json out/quant.sf; do"), run)
        XCTAssertTrue(run.contains("for path in index/ref.idx; do"), run)
        let readme = try text(folder, "README.txt")
        for words in [batch.placements[0], "\(Self.staging)/batches/batch/<sample>/staged/", "index/ref.idx"] {
            XCTAssertTrue(readme.contains(words), "README.txt says \(words)")
        }
        XCTAssertFalse(readme.contains("import fastq"), "a schema 2 batch is adopted by no read import")
        let dryRun = try ExecutorPlanBatchWriter.dryRun([job], image: image, layout: layout)
        XCTAssertTrue(dryRun.contains(batch.placements[0]), "\(dryRun)")
    }

    /// Item 4. A schema 2 job with no memory, CPUs or disk of its own is refused with field `request`, as is a memory
    /// over the regular pool's limit and a CPU count under 1, and no folder is written.
    func testSchemaTwoJobWithoutSubmitValuesIsRefusedWithRequest() throws {
        let cases: [(job: ExecutorPlanBatchJob, words: String)] = [
            (try job(memory: nil), "has no request memory"),
            (try job(cpus: nil, disk: nil), "has no request CPUs or disk"),
            (try job(memory: 102_401), "102401 MiB of memory, over the limit of 102400 MiB"),
            (try job(cpus: 0), "0 CPUs"),
        ]
        for (index, item) in cases.enumerated() {
            let folder = root.appendingPathComponent("refused-\(index)", isDirectory: true)
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.write([item.job], image: image, layout: layout, into: folder)) { error in
                let refusal = error as? ExecutorPlanError
                XCTAssertEqual(refusal?.field, "request", "\(error)")
                XCTAssertTrue(refusal?.reason.contains(item.words) == true, "\(error)")
            }
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.dryRun([item.job], image: image, layout: layout))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }
}
