// HTCondorDAGTests.swift - The run.dag text, one JOB a sample with its VARS (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class HTCondorDAGTests: XCTestCase {
    static let staging = HTCondorSubmitTemplateTests.staging

    static func node(_ sample: String, diskGB: Int) -> HTCondorDAGNode {
        HTCondorDAGNode(
            sample: sample,
            requestDiskGB: diskGB,
            planTarPath: "plan.tar",
            reads: [
                HTCondorStagedFile(url: "\(staging)/reads/\(sample)-r1.fastq.gz", relativePath: "inputs/R1.fastq.gz"),
                HTCondorStagedFile(url: "\(staging)/reads/\(sample)-r2.fastq.gz", relativePath: "inputs/R2.fastq.gz"),
            ]
        )
    }

    /// The DAG of `nodes` at the batch writer's number of jobs at once.
    static func render(_ nodes: [HTCondorDAGNode]) throws -> String {
        try HTCondorDAG.render(nodes, maxJobs: ExecutorPlanBatchWriter.concurrentJobs)
    }

    /// The `key="value"` pairs of one `VARS` line, in order.
    private func variables(of line: Substring) throws -> [(key: String, value: String)] {
        let expression = try NSRegularExpression(pattern: #"([A-Za-z_]+)="([^"]*)""#)
        let text = String(line)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else {
                return nil
            }
            return (String(text[key]), String(text[value]))
        }
    }

    func testDAGPutsRequestDiskInVarsOnly() throws {
        let dag = try Self.render([Self.node("C079876", diskGB: 317), Self.node("VSP2", diskGB: 41)])
        let lines = dag.split(separator: "\n").filter { $0.hasPrefix("JOB ") || $0.hasPrefix("VARS ") }
        XCTAssertEqual(lines.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }, [
            "JOB C079876", "VARS C079876", "JOB VSP2", "VARS VSP2",
        ])
        XCTAssertEqual(lines[0], "JOB C079876 sample.sub")

        // The disk value sits in VARS as a whole number of GB, and in no other value or line.
        let first = try variables(of: lines[1])
        XCTAssertEqual(first.map(\.key), ["sample", "request_disk", "sample_inputs", "sample_placements"])
        XCTAssertEqual(first[1].value, "317GB")
        XCTAssertEqual(try variables(of: lines[3])[1].value, "41GB")
        XCTAssertEqual(dag.components(separatedBy: "317").count - 1, 1, "317 appears once, in VARS")
        for pair in first where pair.key != "request_disk" {
            XCTAssertFalse(pair.value.contains("GB"), "\(pair.key) holds no disk value")
        }
        XCTAssertEqual(
            first[2].value,
            "plan.tar, \(Self.staging)/reads/C079876-r1.fastq.gz, \(Self.staging)/reads/C079876-r2.fastq.gz"
        )
        XCTAssertEqual(first[3].value, "C079876-r1.fastq.gz=inputs/R1.fastq.gz C079876-r2.fastq.gz=inputs/R2.fastq.gz")

        // The submit file reads the value from VARS alone and passes it to no argument and no environment.
        let template = try HTCondorSubmitTemplate.render(HTCondorSubmitTemplateInput.sample)
        let mentions = template.split(separator: "\n").filter { $0.contains("request_disk") && !$0.hasPrefix("#") }
        XCTAssertEqual(mentions, ["request_disk = $(request_disk)"])
        let arguments = try XCTUnwrap(template.split(separator: "\n").first { $0.hasPrefix("arguments = ") })
        XCTAssertFalse(arguments.contains("request_disk"))
        XCTAssertFalse(arguments.contains("GB"))
        XCTAssertFalse(template.contains("environment"), "the job's environment is HTCondor's own")
        XCTAssertFalse(template.contains("getenv"))

        // Two batches that differ only in their disk values differ only in the request_disk values.
        let other = try Self.render([Self.node("C079876", diskGB: 634), Self.node("VSP2", diskGB: 82)])
        XCTAssertNotEqual(dag, other)
        let normalized = { (text: String) in
            text.replacingOccurrences(of: #"request_disk="[0-9]+GB""#, with: #"request_disk="""#, options: .regularExpression)
        }
        XCTAssertEqual(normalized(dag), normalized(other))
    }

    /// A node that names its result folders gets one `SCRIPT PRE` line after its VARS line that makes them all on the
    /// access point before DAGMan submits the node's job, since a `file://` upload makes no folder (fix G3). A node with
    /// no folder renders no script line, and a folder the script line cannot hold is refused.
    func testDagMakesEachResultFolderBeforeItsJob() throws {
        let result = { (sample: String) in
            ["result", "result/out", "result/work"].map { "/staging/groups/g/1/lge/batches/b/\(sample)/\($0)" }
        }
        var first = Self.node("S1", diskGB: 4)
        first.resultFolders = result("S1")
        var second = Self.node("S2", diskGB: 4)
        second.resultFolders = result("S2")
        let dag = try Self.render([first, second, Self.node("S3", diskGB: 4)])
        let lines = dag.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("CATEGORY ") }
            .filter { !$0.hasPrefix("MAXJOBS ") && !$0.hasPrefix("NODE_STATUS_FILE ") }
        XCTAssertEqual(lines.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }, [
            "JOB S1", "VARS S1", "SCRIPT PRE", "JOB S2", "VARS S2", "SCRIPT PRE", "JOB S3", "VARS S3",
        ])
        XCTAssertEqual(lines.filter { $0.hasPrefix("SCRIPT") }, [
            "SCRIPT PRE S1 /bin/mkdir -p /staging/groups/g/1/lge/batches/b/S1/result "
                + "/staging/groups/g/1/lge/batches/b/S1/result/out /staging/groups/g/1/lge/batches/b/S1/result/work",
            "SCRIPT PRE S2 /bin/mkdir -p /staging/groups/g/1/lge/batches/b/S2/result "
                + "/staging/groups/g/1/lge/batches/b/S2/result/out /staging/groups/g/1/lge/batches/b/S2/result/work",
        ])
        for folder in ["/staging/groups/our lab/b/S1/result", "/staging/groups/g/b/S1/result; rm -rf /staging"] {
            var node = Self.node("S1", diskGB: 4)
            node.resultFolders = [result("S1")[0], folder]
            XCTAssertThrowsError(try Self.render([node]), "folder \(folder)")
        }
    }

    /// D15. The plan tar comes from the sample's folder of the home submit folder, the job's `initialdir`, so the node
    /// names it by a relative path of names that ends in plan.tar. A staging URL, a path that climbs out of the folder and
    /// a path that ends in another name are refused.
    func testDAGTakesThePlanTarByAPathRelativeToTheSampleFolder() throws {
        let dag = try Self.render([Self.node("S1", diskGB: 4)])
        let vars = try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS S1 ") })
        XCTAssertEqual(try variables(of: vars)[2].value.components(separatedBy: ", ").first, "plan.tar")
        var nested = Self.node("S1", diskGB: 4)
        nested.planTarPath = "tars/plan.tar"
        XCTAssertNoThrow(try Self.render([nested]))
        for path in ["\(Self.staging)/h/S1/plan.tar", "../S1/plan.tar", "/home/u/S1/plan.tar", "S1.tar", "plan tar/plan.tar"] {
            var node = Self.node("S1", diskGB: 4)
            node.planTarPath = path
            XCTAssertThrowsError(try Self.render([node]), path) { error in
                guard case .invalidValue(let field, _) = error as? HTCondorSubmitError else {
                    return XCTFail("\(path): \(error)")
                }
                XCTAssertEqual(field, "plan tar path of S1", path)
            }
        }
    }

    /// D13 (CHTC-c5 ruling 3b). One category holds every node, at most the writer's number of jobs run at once, and DAGMan
    /// writes every node's state to run.dag.status each minute. The lines follow the last node, so ALL_NODES names them all.
    func testDAGThrottlesEveryNodeAndWritesItsStatusFile() throws {
        let dag = try Self.render([Self.node("S1", diskGB: 4), Self.node("S2", diskGB: 4)])
        let lines = dag.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        let pinned = ["CATEGORY ALL_NODES lge", "MAXJOBS lge 10", "NODE_STATUS_FILE run.dag.status 60"]
        for line in pinned {
            XCTAssertEqual(lines.filter { $0 == line }.count, 1, "\(line) once in: \(dag)")
        }
        XCTAssertEqual(Array(lines.suffix(3)), pinned, "the three lines follow the last node: \(dag)")
        XCTAssertEqual(ExecutorPlanBatchWriter.concurrentJobs, 10, "the writer's one value")

        // The value is the caller's, and a DAG that would run no job is refused.
        let three = try HTCondorDAG.render([Self.node("S1", diskGB: 4)], maxJobs: 3)
        XCTAssertEqual(three.split(separator: "\n").filter { $0.hasPrefix("MAXJOBS ") }, ["MAXJOBS lge 3"])
        XCTAssertThrowsError(try HTCondorDAG.render([Self.node("S1", diskGB: 4)], maxJobs: 0)) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .invalidValue(field: "number of jobs at once", rule: "is under 1."))
        }
    }

    /// D1 (ARCH-c5 point 1, condition 2). The written batch's `SCRIPT PRE` makes, in one `mkdir -p` line a sample, the
    /// folder of every file the job uploads to the staging side, since an upload to a `file://` remap makes no folder
    /// (fix G3). The test reads the written `sample.sub` and `run.dag` of a plan with two reports.
    func testPreScriptMakesEveryRemapFolder() throws {
        let root = try TestTempDirectory.make(prefix: "HTCondorDAGPre")
        defer { try? FileManager.default.removeItem(at: root) }
        var request = try ExecutorPlanTestSupport.request(
            root: root, "S", inputs: ExecutorPlanTestSupport.writePair(root: root, "S"), clumping: .bbtools
        ).templateRequest
        request.recipe = Recipe(formatVersion: 1, id: "plan-test", name: "Plan Test", platforms: [.illumina],
                                requiredInput: .paired,
                                steps: ["fastp-dedup", "fastp-trim", "fastp-merge"].map { RecipeStep(type: $0) })
        request.recipeFile = try ExecutorPlanTestSupport.recipeSource(root: root)
        let recipeTemplate = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let rows = try ["S1", "S2"].map { sample in
            ExecutorPlanSampleRow(sampleName: sample, inputs: try ExecutorPlanTestSupport.writePair(root: root, sample)
                .map { try ExecutorPlanSourceFile.measuring($0) }, requestDiskGiB: nil)
        }
        let image = ExecutorPlanImageRecord(
            sif: ExecutorPlanImageFile(fileName: "lge-tools.sif", sha256: String(repeating: "e", count: 64), size: 4096),
            imageManifest: PlanImageManifestPin(sha256: ExecutorPlanTestSupport.digest, size: 4096)
        )
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(
            recipeTemplate, request: request, rows: rows, image: image,
            layout: ExecutorPlanStagingLayout(folder: "/staging/groups/g/1/lge", batch: "batch"), into: folder
        )
        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        let remapLine = try XCTUnwrap(submit.split(separator: "\n").first { $0.hasPrefix("transfer_output_remaps = ") })
        let targets = remapLine.dropFirst("transfer_output_remaps = \"".count).dropLast()
            .components(separatedBy: "; ").map { $0.components(separatedBy: " = ").last ?? "" }
        XCTAssertEqual(targets.count, 4, "the record, two reports and the payload: \(remapLine)")
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let lines = dag.split(separator: "\n").map(String.init)
        for sample in ["S1", "S2"] {
            let scripts = lines.filter { $0.hasPrefix("SCRIPT PRE \(sample) ") }
            XCTAssertEqual(scripts.count, 1, "one PRE line for \(sample): \(dag)")
            let prefix = "SCRIPT PRE \(sample) /bin/mkdir -p "
            let script = try XCTUnwrap(scripts.first)
            XCTAssertTrue(script.hasPrefix(prefix), script)
            let made = Set(script.dropFirst(prefix.count).split(separator: " ").map(String.init))
            for target in targets {
                XCTAssertTrue(target.hasPrefix("file:///"), "\(target) is uploaded to the staging side")
                let path = target.dropFirst("file://".count).replacingOccurrences(of: "$(sample)", with: sample)
                let parent = (path as NSString).deletingLastPathComponent
                XCTAssertTrue(made.contains(parent), "\(sample)'s PRE line makes \(parent): \(script)")
            }
        }
    }

    func testDAGRefusesNamesAndValuesDAGManWouldMisread() throws {
        XCTAssertThrowsError(try Self.render([Self.node("VSP2", diskGB: 4), Self.node("vsp2", diskGB: 4)])) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .duplicate(field: "sample", name: "vsp2"))
        }
        for name in ["VSP.2", "VSP+2", "VSP 2", "-VSP2", "parent", "ALL_NODES", ""] {
            XCTAssertThrowsError(try Self.render([Self.node(name, diskGB: 4)]), "sample \(name)")
        }
        XCTAssertThrowsError(try Self.render([Self.node("VSP2", diskGB: 0)])) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .invalidValue(field: "disk request of VSP2", rule: "is under 1 GB."))
        }
        var renamed = Self.node("VSP2", diskGB: 4)
        renamed.planTarPath = "VSP2.tar"
        XCTAssertThrowsError(try Self.render([renamed]))
        XCTAssertThrowsError(try Self.render([]))
    }
}

extension HTCondorSubmitTemplateInput {
    static var sample: HTCondorSubmitTemplateInput { HTCondorSubmitTemplateTests.input() }
}
