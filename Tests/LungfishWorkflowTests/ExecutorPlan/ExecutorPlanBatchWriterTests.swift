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
        XCTAssertEqual(names, ["S1", "S2", "lge-job.sh", "logs", "run.dag", "sample.sub", "staging", "staging-files.json"])

        // Each sample's plan folder holds its plan, its staging.json and no read, executor or database.
        for (index, sample) in ["S1", "S2"].enumerated() {
            let planFolder = folder.appendingPathComponent(sample)
            let plan = try ExecutionPlan.decode(Data(contentsOf: planFolder.appendingPathComponent("plan.json")))
            XCTAssertEqual(plan.sample.sampleName, sample)
            XCTAssertEqual(plan, try recipeTemplate.emission(for: rows[index]).plan)
            for entry in plan.entries where entry.role != .recipe {
                XCTAssertFalse(FileManager.default.fileExists(atPath: planFolder.appendingPathComponent(entry.relativePath).path), entry.relativePath)
            }
            let tar = try DeterministicTarReader.entries(in: folder.appendingPathComponent("staging/\(sample)/plan.tar"))
            XCTAssertEqual(tar["plan/plan.json"], try Data(contentsOf: planFolder.appendingPathComponent("plan.json")))
            XCTAssertNotNil(tar["plan/staging.json"])
        }

        // One JOB and one VARS line a sample, the sheet's disk for S1 and the default for S2.
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let lines = dag.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("JOB ") }, ["JOB S1 sample.sub", "JOB S2 sample.sub"])
        let s1 = try XCTUnwrap(lines.first { $0.hasPrefix("VARS S1 ") })
        XCTAssertTrue(s1.contains("request_disk=\"40GB\""), s1)
        XCTAssertTrue(s1.contains("sample_inputs=\"file:///staging/groups/g/1/lge-chtc-test/batches/batch/S1/plan.tar, file:///staging/groups/g/1/lge-chtc-test/batches/batch/S1/R1.fastq, file:///staging/groups/g/1/lge-chtc-test/batches/batch/S1/R2.fastq\""), s1)
        let s2Bytes = rows[1].inputs.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.hasPrefix("VARS S2 ") })
            .contains("request_disk=\"\(ExecutorPlanBatchWriter.defaultRequestDiskGiB(inputBytes: s2Bytes))GB\""))

        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        XCTAssertTrue(submit.contains("container_image = file:///staging/groups/g/1/lge-chtc-test/images/lge-tools-eae819829358.sif\n"), submit)
        let executor = try XCTUnwrap(recipeTemplate.template.entries.first { $0.role == .executor })
        XCTAssertTrue(submit.contains("file:///staging/groups/g/1/lge-chtc-test/shared/\(executor.sha256)-lungfish-executor"), submit)

        // The list names each staged file with the size the plan, staging.json or the tar states.
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self, from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        XCTAssertEqual(list.files.map(\.role), ["image", "executor", "plan-tar", "input", "input", "plan-tar", "input", "input"])
        XCTAssertEqual(list.files[3].size, rows[0].inputs[0].size)
        XCTAssertEqual(list.files[3].source, rows[0].inputs[0].url.path)
        XCTAssertNil(list.files[0].source)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("lge-job.sh").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    /// Fix G3. A `file://` upload makes no folder: G3's tiny jobs 593396 and 593397 were held at code 12 subcode 256,
    /// "Can't open .../out/sample.fastq.gz for writing", when the payload's folder did not exist, and 593394 returned the
    /// payload when it did. So `staging-files.json` names each sample's payload folder to make before the submit, the
    /// folder the submit file's remap writes into.
    func testStagingListNamesEachSamplesPayloadFolderToMakeBeforeTheSubmit() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let rows = [try row("S1"), try row("S2")]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                                      layout: layout, into: folder)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        let folders = try XCTUnwrap((object as? [String: Any])?["folders"] as? [[String: String]], "staging-files.json lists folders")
        XCTAssertEqual(folders.map { $0["role"] }, ["payload-folder", "payload-folder"])
        XCTAssertEqual(folders.map { $0["sample"] }, ["S1", "S2"])
        let paths = ["/staging/groups/g/1/lge-chtc-test/batches/batch/S1/out", "/staging/groups/g/1/lge-chtc-test/batches/batch/S2/out"]
        XCTAssertEqual(folders.map { $0["stagingPath"] }, paths)
        XCTAssertEqual(batch.samples.count, folders.count)
        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        XCTAssertTrue(submit.contains(" = file:///staging/groups/g/1/lge-chtc-test/batches/batch/$(sample)/out/sample.fastq.gz"), submit)
    }

    /// The written `run.dag` makes each sample's payload folder before it submits the sample's job, the folder that
    /// `staging-files.json` names, so no one makes a folder by hand (the review of fix G3, the wrapper question).
    func testRunDagMakesEachSamplesPayloadFolderBeforeItsJob() throws {
        let (request, recipeTemplate) = try bbtoolsTemplate()
        let rows = [try row("S1"), try row("S2")]
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(recipeTemplate, request: request, rows: rows, image: image,
                                          layout: layout, into: folder)
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let lines = dag.split(separator: "\n").map(String.init)
        let list = try JSONDecoder().decode(ExecutorPlanBatchFiles.self, from: Data(contentsOf: folder.appendingPathComponent("staging-files.json")))
        XCTAssertEqual(list.folders.map(\.stagingPath), [
            "/staging/groups/g/1/lge-chtc-test/batches/batch/S1/out", "/staging/groups/g/1/lge-chtc-test/batches/batch/S2/out",
        ])
        for made in list.folders {
            let script = "SCRIPT PRE \(made.sample) /bin/mkdir -p \(made.stagingPath)"
            XCTAssertEqual(lines.filter { $0 == script }.count, 1, "\(script) once in: \(dag)")
            let job = try XCTUnwrap(lines.firstIndex(of: "JOB \(made.sample) sample.sub"), dag)
            XCTAssertEqual(lines.firstIndex(of: script).map { $0 > job }, true, "the script follows its node's JOB line")
        }
        XCTAssertEqual(lines.filter { $0.hasPrefix("SCRIPT ") }.count, 2, dag)
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
             field: "folder", names: "submit folder name"),
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
        let tars = batch.files.filter { $0.role == "plan-tar" }
        XCTAssertEqual(tars.map(\.sample), ["S_1", "S_1-2"])
        XCTAssertTrue(try XCTUnwrap(tars.last).stagingPath.hasSuffix("/S_1-2/plan.tar"), tars.last?.stagingPath ?? "")
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
            "\"plan/out/sample.fastq.gz = file:///staging/groups/g/1/lge-chtc-test/batches/batch/$(sample)/out/sample.fastq.gz; "
                + "sample_fused_fastp_report.json = work/sample_fused_fastp_report.json; "
                + "sample_merge_fastp_report.json = work/sample_merge_fastp_report.json\""
        )
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
