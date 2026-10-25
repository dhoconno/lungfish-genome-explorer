// ExecutorPlanBatchWriterTests.swift - The submit folder of a CHTC batch and the steps with no plan form (CHTC C4 lane F M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorPlanBatchWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanBatch")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private let image = ExecutorPlanImageRecord(
        sif: ExecutorPlanImageFile(fileName: "lge-tools-eae819829358.sif", sha256: String(repeating: "e", count: 64), size: 396_402_688),
        imageManifest: PlanImageManifestPin(sha256: ExecutorPlanTestSupport.digest, size: 4096)
    )
    private let layout = ExecutorPlanStagingLayout(folder: "/staging/groups/g/1/lge-chtc-test", batch: "batch")

    private func row(_ sample: String, disk: Int? = nil) throws -> ExecutorPlanSampleRow {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, sample)
        return ExecutorPlanSampleRow(sampleName: sample, inputs: try pair.map { try ExecutorPlanSourceFile.measuring($0) },
                                     requestDiskGiB: disk)
    }

    func testWritePlanWritesOneFolderPerSampleAndTheDAG() throws {
        let request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools
        ).templateRequest
        let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let rows = [try row("S1", disk: 40), try row("S2")]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                                      layout: layout, into: folder)
        XCTAssertEqual(batch.samples, ["S1", "S2"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["README.txt", "S1", "S2", "jobs.tsv", "lge-job.sh", "logs", "run-local.sh", "run.dag",
                               "sample.sub", "staging-files.json"])

        // Each sample's plan folder holds its plan, its staging.json, its plan tar and no read, executor or database.
        for (index, sample) in ["S1", "S2"].enumerated() {
            let planFolder = folder.appendingPathComponent(sample)
            let plan = try ExecutionPlan.decode(Data(contentsOf: planFolder.appendingPathComponent("plan.json")))
            XCTAssertEqual(plan.sample.sampleName, sample)
            XCTAssertEqual(plan, try recipeTemplate.emission(for: rows[index]).plan)
            for entry in plan.entries where entry.role != .recipe {
                XCTAssertFalse(FileManager.default.fileExists(atPath: planFolder.appendingPathComponent(entry.relativePath).path), entry.relativePath)
            }
            let tar = try DeterministicTarReader.entries(in: folder.appendingPathComponent("\(sample)/plan.tar"))
            XCTAssertEqual(tar["plan/plan.json"], try Data(contentsOf: planFolder.appendingPathComponent("plan.json")))
            XCTAssertNotNil(tar["plan/staging.json"])
        }

        // One JOB and one VARS line a sample, the sheet's disk for S1 and the default for S2.
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let lines = dag.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("JOB ") }, ["JOB S1 sample.sub", "JOB S2 sample.sub"])
        let s1 = try XCTUnwrap(lines.first { $0.hasPrefix("VARS S1 ") })
        XCTAssertTrue(s1.contains("request_disk=\"40GB\""), s1)
        XCTAssertTrue(s1.contains("sample_inputs=\"plan.tar, file:///staging/groups/g/1/lge-chtc-test/batches/batch/S1/R1.fastq, file:///staging/groups/g/1/lge-chtc-test/batches/batch/S1/R2.fastq\""), s1)
        let s2Bytes = rows[1].inputs.reduce(Int64(0)) { $0 + $1.size }
        let sharedBytes = recipeTemplate.template.entries.filter { $0.role == .executor || $0.role == .database }
            .reduce(Int64(0)) { $0 + $1.size }
        let s2Disk = ExecutorPlanBatchWriter.requestDiskGiB(inputBytes: s2Bytes, imageBytes: image.sif.size,
                                                            planTarBytes: batch.planTars[1].size, sharedBytes: sharedBytes)
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.hasPrefix("VARS S2 ") }).contains("request_disk=\"\(s2Disk)GB\""))

        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        XCTAssertTrue(submit.contains("container_image = file:///staging/groups/g/1/lge-chtc-test/images/lge-tools-eae819829358.sif\n"), submit)
        let executor = try XCTUnwrap(recipeTemplate.template.entries.first { $0.role == .executor })
        XCTAssertTrue(submit.contains("file:///staging/groups/g/1/lge-chtc-test/shared/\(executor.sha256)-lungfish-executor"), submit)

        // The list names each staged file with the size the plan, staging.json or the tar states.
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self, from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        XCTAssertEqual(list.files.map(\.role), ["image", "executor", "input", "input", "input", "input"])
        XCTAssertEqual(list.files[2].size, rows[0].inputs[0].size)
        XCTAssertEqual(list.files[2].source, rows[0].inputs[0].url.path)
        XCTAssertNil(list.files[0].source)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("lge-job.sh").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    /// Fix G3. A `file://` upload makes no folder: G3's tiny jobs 593396 and 593397 were held at code 12 subcode 256,
    /// "Can't open .../out/sample.fastq.gz for writing", when the payload's folder did not exist, and 593394 returned the
    /// payload when it did. So `staging-files.json` names each folder of a sample's result to make before the submit,
    /// the folders the submit file's remaps write into (C5 D1): `result/` for the record and `result/out/` for the payload.
    func testStagingListNamesEachSamplesResultFoldersToMakeBeforeTheSubmit() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let rows = [try row("S1"), try row("S2")]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                                      layout: layout, into: folder)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        let folders = try XCTUnwrap((object as? [String: Any])?["folders"] as? [[String: String]], "staging-files.json lists folders")
        XCTAssertEqual(folders.map { $0["role"] }, Array(repeating: "result-folder", count: 4))
        XCTAssertEqual(folders.map { $0["sample"] }, ["S1", "S1", "S2", "S2"])
        let paths = ["S1/result", "S1/result/out", "S2/result", "S2/result/out"]
            .map { "/staging/groups/g/1/lge-chtc-test/batches/batch/\($0)" }
        XCTAssertEqual(folders.map { $0["stagingPath"] }, paths)
        XCTAssertEqual(batch.folders.map(\.stagingPath), paths)
        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        XCTAssertTrue(submit.contains(" = file:///staging/groups/g/1/lge-chtc-test/batches/batch/$(sample)/result/out/sample.fastq.gz"), submit)
        XCTAssertTrue(submit.contains(" = file:///staging/groups/g/1/lge-chtc-test/batches/batch/$(sample)/result/run-record.json"), submit)
    }

    /// The written `run.dag` makes each sample's result folders in one `SCRIPT PRE` line before it submits the sample's
    /// job, the folders that `staging-files.json` names, so no one makes a folder by hand (the review of fix G3).
    func testRunDagMakesEachSamplesResultFoldersBeforeItsJob() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let rows = [try row("S1"), try row("S2")]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                          layout: layout, into: folder)
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let lines = dag.split(separator: "\n").map(String.init)
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self, from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        XCTAssertEqual(Set(list.folders.map(\.sample)), ["S1", "S2"])
        for sample in ["S1", "S2"] {
            let made = list.folders.filter { $0.sample == sample }.map(\.stagingPath)
            let script = "SCRIPT PRE \(sample) /bin/mkdir -p \(made.joined(separator: " "))"
            XCTAssertEqual(lines.filter { $0 == script }.count, 1, "\(script) once in: \(dag)")
            let job = try XCTUnwrap(lines.firstIndex(of: "JOB \(sample) sample.sub"), dag)
            XCTAssertEqual(lines.firstIndex(of: script).map { $0 > job }, true, "the script follows its node's JOB line")
        }
        XCTAssertEqual(lines.filter { $0.hasPrefix("SCRIPT ") }.count, 2, dag)
    }

    /// D17 (CHTC-c5 ruling 3a). With no sheet value a job asks the larger of C4's rule and
    /// ceil(1.25 × (SIF + 2 × tar + F + w × I) / GiB). S10's three runs keep C4's 10, 10 and 9 GB, a 61.6 GB sample asks
    /// 366 GB where C4's rule asked 181, and the rendered `VARS` carries each value. A sheet value still wins.
    func testRequestDiskIsTheLargerOfTheDefaultAndTheWorkRootRule() throws {
        let sif: Int64 = 396_402_688
        let tar: Int64 = 18_432
        let vsp2 = "vsp2-target-enrichment", wastewater = "wastewater-metagenomics"
        let cases: [(run: String, preset: String, inputs: Int64, shared: Int64, disk: Int)] = [
            ("SRR35520572", vsp2, 422_847_301, 3_338_092_947, 10),
            ("SRR24403534", wastewater, 372_364_449, 3_348_200_894, 10),
            ("SRR38262740", wastewater, 94_232_530, 3_348_200_894, 9),
            ("C079876", vsp2, 61_600_000_000, 3_338_092_947, 366),
            ("WW10GB", wastewater, 10_000_000_000, 3_348_200_894, 128),
            ("VSP210GB", vsp2, 10_000_000_000, 3_348_200_894, 63),
        ]
        XCTAssertEqual(ExecutorPlanBatchWriter.workRootFactor(forPreset: vsp2), 5.03)
        XCTAssertEqual(ExecutorPlanBatchWriter.workRootFactor(forPreset: wastewater), 10.61)
        XCTAssertEqual(ExecutorPlanBatchWriter.workRootFactor(forPreset: "a-preset-with-no-node"), 10.61, "the largest value")
        XCTAssertEqual(ExecutorPlanBatchWriter.workRootFactor(forPreset: nil), 10.61, "the largest value")
        XCTAssertEqual(ExecutorPlanBatchWriter.defaultRequestDiskGiB(inputBytes: 61_600_000_000), 181)
        for item in cases {
            let disk = ExecutorPlanBatchWriter.requestDiskGiB(inputBytes: item.inputs, imageBytes: sif, planTarBytes: tar,
                                                              sharedBytes: item.shared,
                workRootFactor: ExecutorPlanBatchWriter.workRootFactor(forPreset: item.preset))
            let node = HTCondorDAGNode(
                sample: item.run, requestDiskGB: disk, planTarPath: "plan.tar",
                reads: [HTCondorStagedFile(url: "file:///staging/g/\(item.run)/R1.fastq.gz", relativePath: "inputs/R1.fastq.gz")]
            )
            let dag = try HTCondorDAG.render([node], maxJobs: ExecutorPlanBatchWriter.concurrentJobs)
            let vars = try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS ") })
            XCTAssertTrue(vars.contains("request_disk=\"\(item.disk)GB\""), "\(item.run): \(vars)")
        }

        // The sheet's column wins over the rule, at the value the sheet gives.
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let folder = root.appendingPathComponent("sheet", isDirectory: true)
        try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1", disk: 3), try row("S2")],
                                          image: image, layout: layout, into: folder)
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS S1 ") }).contains("request_disk=\"3GB\""), dag)
        XCTAssertTrue(try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS S2 ") }).contains("request_disk=\"9GB\""), dag)
    }

    /// D9. A requirements value reaches the one `requirements` line of `sample.sub` whole, and a value that line cannot
    /// hold is refused before any folder is written, with the option to change.
    func testWritePlanJobRequirementsReplaceTheClauseOrAreRefused() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let value = #"(TARGET.OpSysMajorVer >= 9) && (TARGET.Arch == "X86_64")"#
        let folder = root.appendingPathComponent("requirements", isDirectory: true)
        try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1")], image: image,
                                          layout: layout, requirements: value, into: folder)
        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        XCTAssertEqual(submit.split(separator: "\n").filter { $0.hasPrefix("requirements = ") }, ["requirements = \(value)"])
        let refused = root.appendingPathComponent("refused", isDirectory: true)
        XCTAssertThrowsError(try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1")],
                                                               image: image, layout: layout, requirements: "(A)\n(B)",
                                                               into: refused)) { error in
            XCTAssertEqual((error as? ExecutorPlanError)?.field, "requirements", "\(error)")
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("--job-requirements") == true, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    }

    /// D15. Each sample's plan tar is about 18 KB, so the job takes it from the submit folder through `initialdir`, not
    /// from the staging folder: the tar sits in the sample's own folder, VARS names it by a path relative to that folder,
    /// and `staging-files.json` no longer lists it.
    func testPlanTarComesFromTheSubmitFolderAndLeavesTheStagingList() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1"), try row("S2")], image: image,
                                          layout: layout, into: folder)
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self, from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        XCTAssertFalse(list.files.contains { $0.role == "plan-tar" || $0.stagingPath.hasSuffix("/plan.tar") }, "\(list.files)")
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        for sample in ["S1", "S2"] {
            let tar = folder.appendingPathComponent("\(sample)/plan.tar")
            let entries = try DeterministicTarReader.entries(in: tar)
            XCTAssertEqual(entries["plan/plan.json"], try Data(contentsOf: folder.appendingPathComponent("\(sample)/plan.json")))
            XCTAssertNil(entries["plan/plan.tar"], "the tar does not hold itself")
            let vars = try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS \(sample) ") }, dag)
            XCTAssertTrue(vars.contains("sample_inputs=\"plan.tar, file:///staging/"), String(vars))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("staging").path))
        // The tar's size and SHA-256 stay pinned in the writer's result.
        let batch = try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1")], image: image,
                                                      layout: layout, into: root.appendingPathComponent("pinned", isDirectory: true))
        let tar = try Data(contentsOf: root.appendingPathComponent("pinned/S1/plan.tar"))
        XCTAssertEqual(batch.planTars, [ExecutorPlanBatchTar(sample: "S1", relativePath: "S1/plan.tar", size: Int64(tar.count),
                                                             sha256: PortableDigest.sha256Hex(of: tar))])
    }

    /// The bbtools template request for `S1` and its recipe template, which the refusal tests below share.
    private func bbtoolsTemplate() throws -> (request: ExecutorPlanTemplateRequest, recipeTemplate: ExecutorPlanTemplate) {
        let request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools
        ).templateRequest
        return (request, try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24))
    }

    /// A submit folder named with a space, or a staging folder with a space in it, ends in a transfer line that cannot
    /// hold it. The writer refuses both before it writes, with the option or folder to change.
    func testWritePlanRefusesNamesTheTransferLinesCannotHold() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let rows = [try row("S1")]
        let cases = [
            (layout: ExecutorPlanStagingLayout(folder: "/staging/groups/g/1/lge-chtc-test", batch: "VSP2 test"),
             field: "folder", names: "plan folder name"),
            (layout: ExecutorPlanStagingLayout(folder: "/staging/groups/our lab/x", batch: "batch"),
             field: "stagingFolder", names: "--staging-folder"),
        ]
        for (index, item) in cases.enumerated() {
            let target = root.appendingPathComponent("refused-\(index)", isDirectory: true)
            XCTAssertThrowsError(try ExecutorPlanBatchWriter.write(
                recipeTemplate, request: request, rows: rows, image: image, layout: item.layout, into: target
            )) { error in
                let refusal = error as? ExecutorPlanError
                XCTAssertEqual(refusal?.field, item.field, "\(error)")
                XCTAssertTrue(refusal?.reason.contains(item.names) == true, "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), item.field)
        }
    }

    /// C5 ruling 3: a folder that already exists is refused in the one name the command uses for the folder it writes,
    /// the plan folder, with the folder's name and what to do, and the folder is left as it was.
    func testWritePlanRefusesAFolderThatExistsAndCallsItThePlanFolder() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let target = root.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ExecutorPlanBatchWriter.write(
            recipeTemplate, request: request, rows: [try row("S1")], image: image, layout: layout, into: target
        )) { error in
            let refusal = error as? ExecutorPlanError
            XCTAssertEqual(refusal?.field, "folder", "\(error)")
            XCTAssertEqual(refusal?.reason, "The plan folder taken already exists, so name a new folder or remove this one.", "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    /// The sample sanitizer names the folders of a batch (ARCH 4). `S 1` and `S_1` take `S_1` and `S_1-2`, the plan keeps
    /// each sample's own name, and the DAG, the plan folders and the plan tars follow the folder names.
    func testWritePlanNamesFoldersByTheSampleSanitizerAndKeepsTheSampleName() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let rows = [try row("S 1"), try row("S_1")]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                                      layout: layout, into: folder)
        XCTAssertEqual(batch.samples, ["S_1", "S_1-2"])
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        XCTAssertEqual(dag.split(separator: "\n").map(String.init).filter { $0.hasPrefix("JOB ") },
                       ["JOB S_1 sample.sub", "JOB S_1-2 sample.sub"])
        for (name, sampleName) in [("S_1", "S 1"), ("S_1-2", "S_1")] {
            let plan = try ExecutionPlan.decode(Data(contentsOf: folder.appendingPathComponent("\(name)/plan.json")))
            XCTAssertEqual(plan.sample.sampleName, sampleName, name)
        }
        XCTAssertEqual(batch.planTars.map(\.sample), ["S_1", "S_1-2"])
        XCTAssertEqual(batch.planTars.map(\.relativePath), ["S_1/plan.tar", "S_1-2/plan.tar"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("S_1-2/plan.tar").path))
    }

    /// The sanitizer keeps a `.`, which a DAG node name cannot hold, so the writer refuses the sample with the sample to
    /// rename and writes no folder.
    func testWritePlanRefusesASampleNameTheDAGCannotName() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let target = root.appendingPathComponent("refused", isDirectory: true)
        XCTAssertThrowsError(try ExecutorPlanBatchWriter.write(
            recipeTemplate, request: request, rows: [try row("S1.2")], image: image, layout: layout, into: target
        )) { error in
            let refusal = error as? ExecutorPlanError
            XCTAssertEqual(refusal?.field, "sample.sampleName", "\(error)")
            XCTAssertTrue(refusal?.reason.contains("rename the sample") == true, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// AMV2 fix G1: the writer gives the submit template the plan's reports, so a job brings home each report the adopt
    /// reads, at its `work/` path, and no other file of `work/`. The recipe fuses fastp and then merges, so its plan holds
    /// two reports.
    func testWritePlanReturnsEachReportOfATwoReportPlanAndNoOtherWorkFile() throws {
        let request = try templateRequest(recipe: recipe(["fastp-dedup", "fastp-trim", "fastp-merge"]))
        let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let folder = root.appendingPathComponent("reports", isDirectory: true)
        try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1")], image: image,
                                          layout: layout, into: folder)
        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        func value(of command: String) throws -> String {
            let prefix = "\(command) = "
            let lines = submit.split(separator: "\n").filter { $0.hasPrefix(prefix) }
            XCTAssertEqual(lines.count, 1, "lines that set \(command)")
            return String(try XCTUnwrap(lines.first).dropFirst(prefix.count))
        }
        let outputs = try value(of: "transfer_output_files").components(separatedBy: ", ")
        XCTAssertEqual(
            outputs.filter { $0.hasPrefix("plan/work") },
            ["plan/work/sample_fused_fastp_report.json", "plan/work/sample_merge_fastp_report.json"],
            "each report of the plan comes home and nothing else under work/"
        )
        XCTAssertFalse(outputs.contains("plan/work"), "the work folder holds the large intermediates and never comes home")
        let remaps = try value(of: "transfer_output_remaps")
        XCTAssertEqual(
            remaps,
            "\"" + ["run-record.json", "out/sample.fastq.gz", "work/sample_fused_fastp_report.json",
                    "work/sample_merge_fastp_report.json"]
                .map { "plan/\($0) = file:///staging/groups/g/1/lge-chtc-test/batches/batch/$(sample)/result/\($0)" }
                .joined(separator: "; ") + "\""
        )
        // The run.dag makes the reports' folder as well as the record's and the payload's.
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let base = "/staging/groups/g/1/lge-chtc-test/batches/batch/S1"
        XCTAssertTrue(dag.contains("SCRIPT PRE S1 /bin/mkdir -p \(base)/result \(base)/result/out \(base)/result/work\n"), dag)
    }

    /// CHTC-3d R4. The disk a batch asks for follows the recipe's resolved preset: the wastewater batch asks for more than
    /// the VSP2 batch of the same reads, each at its own work root factor.
    func testBatchDiskFollowsTheResolvedPreset() throws {
        var asked: [String: Int] = [:]
        for preset in ["wastewater-metagenomics", "vsp2-target-enrichment"] {
            var request = try templateRequest(recipe: recipe(["fastp-dedup", "fastp-trim", "fastp-merge"]))
            // The resolution is the shipped resolver's own, so the table's key is tied to the recipe file's preset id.
            let real = try XCTUnwrap(RecipeResolver.resolve(preset, in: RecipeRegistryV2.allRecipes()), preset)
            XCTAssertEqual(real.resolution?.preset?.id, preset)
            XCTAssertNotNil(ExecutorPlanBatchWriter.workRootFactors[preset], "\(preset) has a work root factor of its own")
            request.recipe?.resolution = real.resolution
            let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
            let inputs = try ExecutorPlanTestSupport.writePair(root: root, "S1").map { url -> ExecutorPlanSourceFile in
                let measured = try ExecutorPlanSourceFile.measuring(url)
                return ExecutorPlanSourceFile(url: measured.url, sha256: measured.sha256, size: 5_000_000_000)
            }
            let folder = root.appendingPathComponent("preset-\(preset)", isDirectory: true)
            let batch = try ExecutorPlanBatchWriter.write(
                recipeTemplate, request: request, rows: [ExecutorPlanSampleRow(sampleName: "S1", inputs: inputs)],
                image: image, layout: layout, into: folder
            )
            let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
            let vars = try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS S1 ") }, dag)
            let shared = batch.files.filter { $0.sample == nil && $0.role != "image" }.reduce(Int64(0)) { $0 + $1.size }
            let tar = try XCTUnwrap(batch.planTars.first).size
            let factor = preset == "wastewater-metagenomics" ? 10.61 : 5.03
            let bytes = 396_402_688 + 2 * Double(tar) + Double(shared) + factor * 10_000_000_000
            let expected = Int((1.25 * bytes / 1_073_741_824).rounded(.up))
            XCTAssertTrue(vars.contains("request_disk=\"\(expected)GB\""), "\(preset) should ask \(expected) GB: \(vars)")
            asked[preset] = expected
        }
        XCTAssertGreaterThan(try XCTUnwrap(asked["wastewater-metagenomics"]), try XCTUnwrap(asked["vsp2-target-enrichment"]))

        // `--recipe vsp2` is the short name the CLI's own refusal suggests, and it must reach the VSP2 preset and not the
        // largest value. A bare recipe id carries no preset, so its batch asks for the largest value.
        let recipes = RecipeRegistryV2.allRecipes()
        let short = try XCTUnwrap(RecipeResolver.resolve("vsp2", in: recipes))
        XCTAssertEqual(short.resolution?.preset?.id, "vsp2-target-enrichment")
        XCTAssertEqual(ExecutorPlanBatchWriter.workRootFactor(forPreset: short.resolution?.preset?.id), 5.03)
        let bare = try XCTUnwrap(RecipeResolver.resolve("illumina-paired-cleanup", in: recipes))
        XCTAssertNil(bare.resolution?.preset)
        XCTAssertEqual(ExecutorPlanBatchWriter.workRootFactor(forPreset: bare.resolution?.preset?.id), 10.61)
    }

    // MARK: Steps with no plan form, one test each

    private func templateRequest(recipe: Recipe? = nil, suffixes: [String]? = nil, format: RecipeFileFormat = .pairedR1R2,
                                 clumping: ClumpingTool = .bbtools, binning: QualityBinningScheme = .illumina4) throws -> ExecutorPlanTemplateRequest {
        var request = try ExecutorPlanTestSupport.request(
            root: root, "S", inputs: ExecutorPlanTestSupport.writePair(root: root, "S"), clumping: clumping
        ).templateRequest
        request.recipe = recipe
        request.recipeFile = recipe == nil ? nil : try ExecutorPlanTestSupport.recipeSource(root: root)
        request.inputFormat = format
        if let suffixes { request.inputSuffixes = suffixes }
        request.storage.qualityBinning = binning
        return request
    }

    private func recipe(_ types: [String]) -> Recipe {
        Recipe(formatVersion: 1, id: "plan-test", name: "Plan Test", platforms: [.illumina], requiredInput: .paired,
               steps: types.map { RecipeStep(type: $0) })
    }

    private func assertRefused(_ expected: ExecutorPlanNoPlanForm, _ body: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? ExecutorPlanNoPlanForm, expected, file: file, line: line)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("without --write-plan") == true, file: file, line: line)
        }
    }

    func testWritePlanRefusesRiboDetector() throws {
        let request = try templateRequest(recipe: recipe(["ribodetector-filter"]))
        assertRefused(.riboDetector) { try ExecutorPlanNoPlanForm.check(request) }
    }

    /// D18 (C5 lane BF M1). A lone trim step, the built-in recipe's when duplicates are kept, and a user recipe's lone
    /// dedup step each have a plan form, so neither is refused before planning and each plans one fastp step.
    func testWritePlanPlansALoneFastpStep() throws {
        for type in ["fastp-trim", "fastp-dedup"] {
            let request = try templateRequest(recipe: recipe([type]))
            XCTAssertNoThrow(try ExecutorPlanNoPlanForm.check(request), type)
            let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
            XCTAssertEqual(recipeTemplate.template.steps.filter { $0.kind == .recipe }.map { $0.tool?.id }, ["fastp"], type)
        }
    }

    func testWritePlanRefusesInterleavedToPaired() throws {
        let request = try templateRequest(recipe: recipe(["fastp-merge"]), suffixes: [".fastq"], format: .interleaved)
        assertRefused(.interleavedToPaired) { try ExecutorPlanNoPlanForm.check(request) }
    }

    func testWritePlanRefusesTwoFilesWithNoClumpingOrBinning() throws {
        let request = try templateRequest(clumping: ClumpingTool.none, binning: QualityBinningScheme.none)
        let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        assertRefused(.twoFilesWithNoBinning) {
            try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: [try row("S1")], image: image,
                                              layout: layout, into: root.appendingPathComponent("refused"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("refused").path))
    }

    func testWritePlanRefusesOneGzipFileWithNoClumpingOrBinning() throws {
        let request = try templateRequest(suffixes: [".fastq.gz"], format: .single, clumping: ClumpingTool.none,
                                          binning: QualityBinningScheme.none)
        let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        assertRefused(.gzipFileWithNoBinning) { try ExecutorPlanNoPlanForm.check(recipeTemplate.template, request: request) }
    }

    func testWritePlanRefusesMoreThanTwoFiles() throws {
        let request = try templateRequest(suffixes: [".fastq", ".fastq", ".fastq"])
        assertRefused(.moreThanTwoFiles(count: 3)) { try ExecutorPlanNoPlanForm.check(request) }
    }
}
