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

    /// The stand-in plan of one sample and the Mac file of each entry a folder copies. The defaults give the plan of the
    /// first test. The refusal tests change the reference's bytes, leave the chain of pinned tools out, pin another tool
    /// manifest, or name other outputs, each with the policy it has in the step's own order.
    private func emission(
        _ sample: String = "S", referenceText: String = ">t\nA\n", withPipeline: Bool = true, manifest: PlanImageManifestPin? = nil,
        outputs: [(path: String, policy: PlanOutputPolicy)] = [("out/quant.sf", .home), ("index/ref.idx", .staged), ("out/reads.bam", .stays)]
    ) throws -> ExecutorPlanEmission {
        let executor = try file("lungfish-executor", "executor stand-in")
        let reads = try file("\(sample)_R1.fastq", "@r\nACGT\n+\nIIII\n")
        // One file for each sample, so a second job's other bytes never overwrite the first job's reference.
        let fasta = try file("\(sample)-transcripts.fa", referenceText)
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
            imageManifest: manifest ?? image.imageManifest, tools: [tool], recipe: nil,
            pipeline: !withPipeline ? nil : PlanPipeline(
                id: "stand-in", version: 1, preset: PlanPipelinePreset(id: "bulk", name: "Stand-in"), modality: .bulk,
                route: PlanPipelineRoute(id: "stand-in", tool: "quant", toolVersion: "1.0", settings: settings),
                referenceSet: PlanPipelineReferenceSet(id: Self.set, layout: .lge),
                settings: settings.keys.sorted().map { PlanPipelineSetting(id: $0, label: $0, value: settings[$0] ?? "", source: .default) }
            ),
            sample: PlanSampleValues(sampleName: sample, originalFilenames: ["\(sample)_R1.fastq"], originalSizeBytes: reads.size),
            storage: nil, clumping: nil, graceSeconds: 5,
            steps: [PlanStep(
                id: "quant", title: "Count", kind: .tool, tool: tool, arguments: [referencePath, "barcodes/mine.txt", "inputs/R1.fastq"],
                deadlineSeconds: 60, inputs: ["inputs/R1.fastq"], outputs: outputs.map(\.path),
                outputPolicy: Dictionary(uniqueKeysWithValues: outputs.map { ($0.path, $0.policy) })
            )]
        )
        let sources = ["bin/lungfish-executor": executor.url, "inputs/R1.fastq": reads.url, referencePath: fasta.url]
        return ExecutorPlanEmission(plan: plan, sources: sources)
    }

    private func job(
        _ sample: String = "S", memory: Int64? = 40_960, cpus: Int? = 8, disk: Int? = 30, emission built: ExecutorPlanEmission? = nil
    ) throws -> ExecutorPlanBatchJob {
        ExecutorPlanBatchJob(
            emission: try built ?? emission(sample),
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

    /// Each node of a batch asks for the memory, CPUs and disk of its own job. Two jobs that differ in their sample and
    /// their figures write two nodes under one sample.sub, two plan tars, and two rows of jobs.tsv that place the same
    /// three shared files and the sample's own read (EX-SUBMIT-SWIFT should-fix 1).
    func testSchemaTwoBatchOfTwoJobsGivesEachNodeItsOwnRequests() throws {
        let big = try job("S", memory: 40_960, cpus: 8, disk: 30)
        let small = try job("T", memory: 2_048, cpus: 1, disk: 2)
        let jobs = [big, small]
        let folder = root.appendingPathComponent("batch-of-two", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write(jobs, image: image, layout: layout, into: folder)
        XCTAssertEqual(batch.samples, ["S", "T"])
        XCTAssertEqual(batch.planTars.map(\.sample), ["S", "T"])

        let base = "\(Self.staging)/batches/batch"
        let dag = try text(folder, "run.dag").split(separator: "\n").map(String.init)
        let asked: [(sample: String, pairs: [String])] = [
            ("S", ["request_memory=\"40960MB\"", "request_cpus=\"8\"", "request_disk=\"30GB\"", "sample_inputs=\"plan.tar, file://\(base)/S/R1.fastq\""]),
            ("T", ["request_memory=\"2048MB\"", "request_cpus=\"1\"", "request_disk=\"2GB\"", "sample_inputs=\"plan.tar, file://\(base)/T/R1.fastq\""]),
        ]
        for item in asked {
            let vars = try XCTUnwrap(dag.first { $0.hasPrefix("VARS \(item.sample) ") }, "\(dag)")
            for pair in item.pairs { XCTAssertTrue(vars.contains(pair), "\(pair) in \(vars)") }
            for other in asked where other.sample != item.sample {
                XCTAssertFalse(vars.contains(other.pairs[0]), "\(item.sample) takes \(other.sample)'s memory: \(vars)")
            }
            let own = "\(base)/\(item.sample)"
            XCTAssertEqual(dag.filter { $0.hasPrefix("SCRIPT PRE \(item.sample) ") },
                           ["SCRIPT PRE \(item.sample) /bin/mkdir -p \(own)/result \(own)/result/out \(own)/staged \(own)/staged/index"])
        }

        let plan = big.emission.plan
        let shared = [
            "shared/\(plan.entries[0].sha256)-lungfish-executor=bin/lungfish-executor",
            "shared/\(plan.entries[2].sha256)-transcripts.fa=references/\(Self.set)/derived/transcripts.fa",
            "shared/\(plan.entries[4].sha256)-mine.txt=barcodes/mine.txt",
        ]
        let rows = try text(folder, "jobs.tsv").split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 3, "the comment line and one row for each sample")
        for (index, name) in ["S", "T"].enumerated() {
            let columns = rows[index + 1].split(separator: "\t").map(String.init)
            XCTAssertEqual(Array(columns.prefix(3)), [name, "\(name)/plan.tar", batch.planTars[index].sha256])
            XCTAssertEqual(Array(columns.dropFirst(3)), shared + ["batches/batch/\(name)/R1.fastq=inputs/R1.fastq"])
            let tar = try DeterministicTarReader.entries(in: folder.appendingPathComponent("\(name)/plan.tar"))
            XCTAssertEqual(tar["plan/plan.json"], try jobs[index].emission.plan.encoded(), "the tar of \(name) holds the plan of \(name)")
        }
        XCTAssertNotEqual(batch.planTars[0].sha256, batch.planTars[1].sha256)
        XCTAssertEqual(batch.folders.filter { $0.sample == "T" }.map(\.role),
                       ["result-folder", "result-folder", "staged-folder", "staged-folder"])
    }

    /// The refusals of `checkJobs` that the test above and the request test leave out, and the submit template's one for two
    /// outputs of one last name. A batch of no plan, a plan with no chain of pinned tools, a second plan whose reference
    /// bytes differ from the first's, and a plan that pins another tool manifest than the image are each refused with the
    /// field and words below, `dryRun` makes the same refusal, and no folder is left. The two returned files of one last name
    /// are refused while the folder is written, so the writer removes the folder it made (EX-SUBMIT-SWIFT should-fix 1).
    func testSchemaTwoBatchRefusalsLeaveNoFolder() throws {
        let another = PlanImageManifestPin(sha256: String(repeating: "9", count: 64), size: 4097)
        let cases: [(name: String, jobs: [ExecutorPlanBatchJob], field: String, words: String)] = [
            ("no-job", [], "sample", "holds no plan"),
            ("no-chain", [try job(emission: try emission(withPipeline: false))], "pipeline", "(schema 2)"),
            ("other-reference", [try job(), try job("T", emission: try emission("T", referenceText: ">t\nC\n"))], "entries",
             "a batch of its own"),
            ("other-manifest", [try job(emission: try emission(manifest: another))], "imageManifest",
             "pins another tool manifest than the image"),
        ]
        for item in cases {
            let folder = root.appendingPathComponent(item.name, isDirectory: true)
            var refusal: ExecutorPlanError?
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.write(item.jobs, image: image, layout: layout, into: folder), item.name) {
                refusal = $0 as? ExecutorPlanError
            }
            XCTAssertEqual(refusal?.field, item.field, item.name)
            XCTAssertTrue(refusal?.reason.contains(item.words) == true, "\(item.name): \(String(describing: refusal))")
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.dryRun(item.jobs, image: image, layout: layout), item.name) {
                XCTAssertEqual($0 as? ExecutorPlanError, refusal, item.name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), item.name)
        }

        // `dryRun` makes the refusals of `checkJobs` and renders nothing, so this one shows in the real write alone.
        let clash = try job(emission: try emission(outputs: [("out/quant.sf", .home), ("index/quant.sf", .staged)]))
        let folder = root.appendingPathComponent("returned-twice", isDirectory: true)
        XCTAssertThrowsError(try ExecutorPlanBatchWriter.write([clash], image: image, layout: layout, into: folder)) {
            XCTAssertEqual($0 as? HTCondorSubmitError, .duplicate(field: "returned file", name: "quant.sf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A job's own memory and CPUs reach its node whether or not its plan stages an output, since every node of a schema 2
    /// batch reads both from `VARS` and a node that left them out would go to HTCondor with an unset macro
    /// (EX-SUBMIT-SWIFT should-fix 3).
    func testSchemaTwoBatchWithHomeOutputsOnlyStillGivesEachNodeItsRequests() throws {
        let only = try job(emission: try emission(outputs: [("out/quant.sf", .home), ("out/reads.bam", .stays)]))
        let folder = root.appendingPathComponent("home-only", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write([only], image: image, layout: layout, into: folder)
        XCTAssertEqual(batch.folders.map(\.role), ["result-folder", "result-folder"], "no staged output, so no staged folder")
        let submit = try text(folder, "sample.sub")
        XCTAssertEqual(try value(of: "request_memory", in: submit), "$(request_memory)")
        XCTAssertEqual(try value(of: "request_cpus", in: submit), "$(request_cpus)")
        let dag = try text(folder, "run.dag").split(separator: "\n").map(String.init)
        let vars = try XCTUnwrap(dag.first { $0.hasPrefix("VARS S ") }, "\(dag)")
        for pair in ["request_memory=\"40960MB\"", "request_cpus=\"8\"", "request_disk=\"30GB\""] {
            XCTAssertTrue(vars.contains(pair), "\(pair) in \(vars)")
        }
    }

    /// The plans of an index build have no `input` entry and no `sample`, so the batch holds a DAG node that reads no
    /// reads. Its row of jobs.tsv names the three shared files and no read, its VARS give the plan tar alone as
    /// `sample_inputs`, and its `home` and `staged` outputs go where a schema 2 plan's go. This is the default stand-in of
    /// ``ExecutorPlanBatchLauncherConformanceTests``, which runs the same plan with the real executor.
    func testIndexShapedPlanWritesANodeWithNoReadsAndReturnsItsStagedIndex() throws {
        typealias Fixture = ExecutorPlanIndexShapeFixture
        let executor = try file("lungfish-executor", "executor stand-in")
        let reference = try file("ref.fa", Fixture.referenceText)
        let list = try file("ids.txt", Fixture.listText)
        let job = Fixture.job(
            executor: try Fixture.Source(executor.url), reference: try Fixture.Source(reference.url),
            list: try Fixture.Source(list.url), seqkit: PlanToolPin(id: "seqkit", version: "2.13.0", build: "b0"),
            pigz: PlanToolPin(id: "pigz", version: "2.8", build: "b0"), imageManifest: image.imageManifest
        )
        XCTAssertNil(job.emission.plan.sampleValues)
        XCTAssertFalse(job.emission.plan.entries.contains { $0.role == .input })
        let folder = root.appendingPathComponent("index-batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write([job], image: image, layout: layout, into: folder)
        XCTAssertEqual(batch.samples, ["index"])

        let shared = "\(Self.staging)/shared"
        let names = [(executor.sha256, "lungfish-executor"), (reference.sha256, "ref.fa"), (list.sha256, "ids.txt")].map { "\($0.0)-\($0.1)" }
        let jobs = try text(folder, "jobs.tsv").split(separator: "\n").map(String.init)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(Array(jobs[1].split(separator: "\t").dropFirst(3)), [
            "shared/\(names[0])=bin/lungfish-executor", "shared/\(names[1])=\(Fixture.referencePath)", "shared/\(names[2])=\(Fixture.listPath)",
        ])
        let submit = try text(folder, "sample.sub")
        XCTAssertEqual(try value(of: "transfer_input_files", in: submit), "$(sample_inputs), " + names.map { "file://\(shared)/\($0)" }.joined(separator: ", "))
        XCTAssertEqual(try value(of: "transfer_output_files", in: submit),
                       "plan/run-record.json, plan/logs, plan/\(Fixture.homeOutput), plan/\(Fixture.stagedOutput)")
        let dag = try text(folder, "run.dag").split(separator: "\n").map(String.init)
        let vars = try XCTUnwrap(dag.first { $0.hasPrefix("VARS index ") })
        for pair in ["request_disk=\"2GB\"", "request_memory=\"2048MB\"", "request_cpus=\"1\"", "sample_inputs=\"plan.tar\""] {
            XCTAssertTrue(vars.contains(pair), "\(pair) in \(vars)")
        }
        let base = "\(Self.staging)/batches/batch/index"
        XCTAssertTrue(dag.contains("SCRIPT PRE index /bin/mkdir -p \(base)/result \(base)/result/out \(base)/staged \(base)/staged/index"), "\(dag)")
        XCTAssertEqual(batch.files.map(\.role), ["image", "executor", "reference", "barcodeList"])
        XCTAssertNil(batch.files[3].source, "LGE never copies a list the person supplied")
        let run = try text(folder, "run-local.sh")
        XCTAssertTrue(run.contains("for path in run-record.json \(Fixture.homeOutput); do"), run)
        XCTAssertTrue(run.contains("for path in \(Fixture.stagedOutput); do"), run)
    }

    /// The stand-in job with the three files of ``ExecutorPlanStagedIndexTests``'s index record pinned, each read where
    /// the batch `m-index` left it (lane EX-PLAN-STAR M1).
    private func stagedIndexJob(_ sample: String = "S", paths: (([String: String]) -> [String: String])? = nil) throws -> ExecutorPlanBatchJob {
        let pinned = try ExecutorPlanStagedIndex.pin(ExecutorPlanStagedIndexTests.record(), star: ExecutorPlanStagedIndexTests.star, layout: layout)
        let made = try emission(sample)
        var plan = made.plan
        // A schema 2 plan lists its reference entries by relativePath, before its barcode lists.
        plan.entries.insert(contentsOf: pinned.entries, at: plan.entries.firstIndex { $0.role == .barcodeList } ?? plan.entries.endIndex)
        return ExecutorPlanBatchJob(
            emission: ExecutorPlanEmission(plan: plan, sources: made.sources), submit: ExecutorPlanSubmitValues(sampleName: sample, requestDiskGiB: 30, requestMemoryMiB: 40_960, requestCpus: 8),
            stagedReferencePaths: paths?(pinned.stagingPaths) ?? pinned.stagingPaths)
    }

    /// Lane EX-PLAN-STAR M1 item 2. Each file of an index an earlier run staged is read where that run left it, as a staged
    /// read is: `staging-files.json` names it there with no source, so nothing uploads it, `sample.sub` transfers it from
    /// there, and `jobs.tsv` places it from the same path below the data folder, never from `shared/<SHA-256>-<name>`. The
    /// plan tar holds no index file, and the README and the dry run say where each index file is read from.
    func testAStagedIndexIsReadWhereItsRunLeftItAndNeverUploaded() throws {
        typealias Staged = ExecutorPlanStagedIndexTests
        let job = try stagedIndexJob()
        let folder = root.appendingPathComponent("staged-index", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write([job], image: image, layout: layout, into: folder)
        let names = Staged.names
        let paths = names.map(Staged.indexPath)

        let staged = batch.files.filter { $0.stagingPath.hasPrefix(Staged.indexFolder + "/") }
        XCTAssertEqual(staged.map(\.stagingPath), names.map { "\(Staged.indexFolder)/\($0)" })
        XCTAssertEqual(staged.map(\.role), ["reference", "reference", "reference"])
        XCTAssertEqual(staged.map(\.source), [nil, nil, nil], "nothing uploads an index an earlier run staged")
        XCTAssertEqual(staged.map(\.sha256), Staged.record().files.map(\.sha256))
        XCTAssertFalse(batch.files.contains { file in names.contains { file.stagingPath.hasSuffix("-\($0)") } }, "\(batch.files)")
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self, from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        XCTAssertEqual(list.files, batch.files)

        let row = try text(folder, "jobs.tsv").split(separator: "\n").map(String.init)[1].split(separator: "\t").map(String.init)
        for (name, path) in zip(names, paths) {
            XCTAssertTrue(row.contains("batches/m-index/index/staged/star-index/\(name)=\(path)"), "\(row)")
        }
        let submit = try text(folder, "sample.sub")
        let inputs = try value(of: "transfer_input_files", in: submit)
        let arguments = try value(of: "arguments", in: submit)
        for (name, path) in zip(names, paths) {
            XCTAssertTrue(inputs.contains("file://\(Staged.indexFolder)/\(name),") || inputs.hasSuffix("file://\(Staged.indexFolder)/\(name)"), inputs)
            XCTAssertTrue(arguments.contains("'\(name)=\(path)'"), arguments)
        }
        XCTAssertFalse(inputs.contains("shared/\(Staged.record().files[0].sha256)"), inputs)

        let tar = try DeterministicTarReader.entries(in: folder.appendingPathComponent("S/plan.tar"))
        XCTAssertEqual(tar["plan/plan.json"], try job.emission.plan.encoded())
        for path in paths { XCTAssertNil(tar["plan/\(path)"]) }

        let words = "The jobs read the 3 files of the index \(Staged.key) (Genome, SA and chrName.txt) where the run that built it "
            + "left them, in \(Staged.indexFolder)/, and nothing copies them. A run of run-local.sh reads them from "
            + "batches/m-index/index/staged/star-index/ below its data folder."
        let readme = try text(folder, "README.txt")
        XCTAssertTrue(readme.contains(words), readme)
        XCTAssertTrue(batch.placements.contains(words), "\(batch.placements)")
        let dryRun = try ExecutorPlanBatchWriter.dryRun([job], image: image, layout: layout)
        XCTAssertTrue(dryRun.contains(words), "\(dryRun)")
    }

    /// Lane EX-PLAN-STAR M1 item 2. A staged index path outside the staging folder, one that names no index file of the
    /// plan, and two jobs that read the index from different places are refused before anything is written.
    func testStagedIndexRefusalsLeaveNoFolder() throws {
        typealias Staged = ExecutorPlanStagedIndexTests
        let genome = Staged.indexPath("Genome")
        let cases: [(name: String, jobs: [ExecutorPlanBatchJob], field: String, words: String)] = [
            ("outside", [try stagedIndexJob { $0.merging([genome: "/elsewhere/Genome"]) { $1 } }], "stagedReferencePaths",
             "/elsewhere/Genome is not inside the staging folder \(Self.staging)"),
            ("not-an-index", [try stagedIndexJob { $0.merging(["inputs/R1.fastq": "\(Self.staging)/reads/R1.fastq"]) { $1 } }],
             "stagedReferencePaths", "inputs/R1.fastq, which is no index file of the plan"),
            ("two-places", [try stagedIndexJob(), try stagedIndexJob("T") { $0.merging([genome: "\(Self.staging)/other/Genome"]) { $1 } }],
             "stagedReferencePaths", "a batch of its own"),
        ]
        for item in cases {
            let folder = root.appendingPathComponent(item.name, isDirectory: true)
            var refusal: ExecutorPlanError?
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.write(item.jobs, image: image, layout: layout, into: folder), item.name) {
                refusal = $0 as? ExecutorPlanError
            }
            XCTAssertEqual(refusal?.field, item.field, item.name)
            XCTAssertTrue(refusal?.reason.contains(item.words) == true, "\(item.name): \(String(describing: refusal))")
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.dryRun(item.jobs, image: image, layout: layout), item.name) {
                XCTAssertEqual($0 as? ExecutorPlanError, refusal, item.name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), item.name)
        }
    }
}
