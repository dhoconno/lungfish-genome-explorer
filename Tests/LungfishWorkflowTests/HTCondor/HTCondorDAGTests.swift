// HTCondorDAGTests.swift - The run.dag text, one JOB a sample with its VARS (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class HTCondorDAGTests: XCTestCase {
    static let staging = HTCondorSubmitTemplateTests.staging

    static func node(_ sample: String, diskGB: Int) -> HTCondorDAGNode {
        HTCondorDAGNode(
            sample: sample,
            requestDiskGB: diskGB,
            planTarURL: "\(staging)/h/\(sample)/plan.tar",
            reads: [
                HTCondorStagedFile(url: "\(staging)/reads/\(sample)-r1.fastq.gz", relativePath: "inputs/R1.fastq.gz"),
                HTCondorStagedFile(url: "\(staging)/reads/\(sample)-r2.fastq.gz", relativePath: "inputs/R2.fastq.gz"),
            ]
        )
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
        let dag = try HTCondorDAG.render([Self.node("C079876", diskGB: 317), Self.node("VSP2", diskGB: 41)])
        let lines = dag.split(separator: "\n").filter { !$0.hasPrefix("#") }
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
            "\(Self.staging)/h/C079876/plan.tar, \(Self.staging)/reads/C079876-r1.fastq.gz, "
                + "\(Self.staging)/reads/C079876-r2.fastq.gz"
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
        let other = try HTCondorDAG.render([Self.node("C079876", diskGB: 634), Self.node("VSP2", diskGB: 82)])
        XCTAssertNotEqual(dag, other)
        let normalized = { (text: String) in
            text.replacingOccurrences(of: #"request_disk="[0-9]+GB""#, with: #"request_disk="""#, options: .regularExpression)
        }
        XCTAssertEqual(normalized(dag), normalized(other))
    }

    /// A node that names its payload folder gets a `SCRIPT PRE` line after its VARS line that makes the folder on the access
    /// point before DAGMan submits the node's job, since the payload's `file://` upload makes no folder (fix G3). A node
    /// with no folder renders no script line, and a folder the script line cannot hold is refused.
    func testDagMakesEachPayloadFolderBeforeItsJob() throws {
        var first = Self.node("S1", diskGB: 4)
        first.payloadFolder = "/staging/groups/g/1/lge/batches/b/S1/out"
        var second = Self.node("S2", diskGB: 4)
        second.payloadFolder = "/staging/groups/g/1/lge/batches/b/S2/out"
        let dag = try HTCondorDAG.render([first, second, Self.node("S3", diskGB: 4)])
        let lines = dag.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }, [
            "JOB S1", "VARS S1", "SCRIPT PRE", "JOB S2", "VARS S2", "SCRIPT PRE", "JOB S3", "VARS S3",
        ])
        XCTAssertEqual(lines.filter { $0.hasPrefix("SCRIPT") }, [
            "SCRIPT PRE S1 /bin/mkdir -p /staging/groups/g/1/lge/batches/b/S1/out",
            "SCRIPT PRE S2 /bin/mkdir -p /staging/groups/g/1/lge/batches/b/S2/out",
        ])
        for folder in ["/staging/groups/our lab/b/S1/out", "/staging/groups/g/b/S1/out; rm -rf /staging"] {
            var node = Self.node("S1", diskGB: 4)
            node.payloadFolder = folder
            XCTAssertThrowsError(try HTCondorDAG.render([node]), "folder \(folder)")
        }
    }

    func testDAGRefusesNamesAndValuesDAGManWouldMisread() throws {
        XCTAssertThrowsError(try HTCondorDAG.render([Self.node("VSP2", diskGB: 4), Self.node("vsp2", diskGB: 4)])) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .duplicate(field: "sample", name: "vsp2"))
        }
        for name in ["VSP.2", "VSP+2", "VSP 2", "-VSP2", "parent", "ALL_NODES", ""] {
            XCTAssertThrowsError(try HTCondorDAG.render([Self.node(name, diskGB: 4)]), "sample \(name)")
        }
        XCTAssertThrowsError(try HTCondorDAG.render([Self.node("VSP2", diskGB: 0)])) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .invalidValue(field: "disk request of VSP2", rule: "is under 1 GB."))
        }
        var renamed = Self.node("VSP2", diskGB: 4)
        renamed.planTarURL = "\(Self.staging)/h/VSP2/VSP2.tar"
        XCTAssertThrowsError(try HTCondorDAG.render([renamed]))
        XCTAssertThrowsError(try HTCondorDAG.render([]))
    }
}

extension HTCondorSubmitTemplateInput {
    static var sample: HTCondorSubmitTemplateInput { HTCondorSubmitTemplateTests.input() }
}
