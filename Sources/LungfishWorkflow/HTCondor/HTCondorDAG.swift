// HTCondorDAG.swift - The run.dag of a CHTC batch, one JOB a sample with its VARS (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One sample's node of `run.dag`: the values its job takes through `VARS`.
public struct HTCondorDAGNode: Sendable, Equatable {
    /// The sample's name. It names the DAG node, the plan folder the job starts in and the job's log.
    public var sample: String
    /// The scratch disk the job asks for, in whole GiB, which the fill writes from the sample's input sizes (C4-05,
    /// CHTC-c4r2 4.1). It reaches the submit file's `request_disk` only, never a plan, an argument or the environment.
    public var requestDiskGB: Int
    /// The sample's plan tar on `/staging`, whose last path component is ``HTCondorSubmitTemplate/planTarName``.
    public var planTarURL: String
    /// The sample's reads on `/staging`, each placed at its plan path by the wrapper.
    public var reads: [HTCondorStagedFile]
    /// The sample's payload folder on `/staging`, which `run.dag` makes with a `SCRIPT PRE` on the access point before
    /// DAGMan submits the node's job. The payload's upload to a `file://` URL makes no folder, and a job with no such
    /// folder is held when it finishes and starts again from the beginning when released (fix G3). `nil` renders no script.
    public var payloadFolder: String?

    public init(sample: String, requestDiskGB: Int, planTarURL: String, reads: [HTCondorStagedFile],
                payloadFolder: String? = nil) {
        self.sample = sample
        self.requestDiskGB = requestDiskGB
        self.planTarURL = planTarURL
        self.reads = reads
        self.payloadFolder = payloadFolder
    }
}

/// The text of `run.dag`: one `JOB` a sample, every one naming ``HTCondorSubmitTemplate/fileName``, and one `VARS` line
/// a sample with its name, its disk request with a `GB` suffix (a bare number would be read as KiB, CHTC-c4r2 4.3), its
/// inputs and the wrapper's placements of its reads.
public enum HTCondorDAG {
    /// The file name lane F's writer gives the DAG.
    public static let fileName = "run.dag"

    /// Words DAGMan reserves, which no node may take as its name.
    static let reservedNodeNames: Set<String> = ["PARENT", "CHILD", "ALL_NODES"]

    public static func render(_ nodes: [HTCondorDAGNode]) throws -> String {
        guard !nodes.isEmpty else {
            throw HTCondorSubmitError.invalidValue(field: "sample list", rule: "is empty.")
        }
        var seen = Set<String>()
        var lines = [
            "# \(fileName) - written by Lungfish for a CHTC batch. One JOB a sample, each with its own VARS.",
        ]
        for node in nodes {
            try validate(node)
            // A case-insensitive file system would put two such samples' logs in one file.
            guard seen.insert(node.sample.uppercased()).inserted else {
                throw HTCondorSubmitError.duplicate(field: "sample", name: node.sample)
            }
            let inputs = ([node.planTarURL] + node.reads.map(\.url)).joined(separator: ", ")
            let placements = node.reads.map(\.placement).joined(separator: " ")
            let variables = [
                (HTCondorSubmitTemplate.sampleVariable, node.sample),
                (HTCondorSubmitTemplate.requestDiskVariable, "\(node.requestDiskGB)GB"),
                (HTCondorSubmitTemplate.inputsVariable, inputs),
                (HTCondorSubmitTemplate.placementsVariable, placements),
            ]
            lines.append("JOB \(node.sample) \(HTCondorSubmitTemplate.fileName)")
            lines.append("VARS \(node.sample) " + variables.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " "))
            // The payload's upload makes no folder, so the access point makes it before DAGMan submits the node's job.
            if let folder = node.payloadFolder {
                lines.append("SCRIPT PRE \(node.sample) /bin/mkdir -p \(folder)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`, none of DAGMan's reserved words. DAGMan keeps `+` and `.` in node names for
    /// splices, and the name is also a folder and a file name.
    static func isNodeName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        func alphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard (1...64).contains(scalars.count), alphanumeric(scalars[0]) else { return false }
        guard !reservedNodeNames.contains(name.uppercased()) else { return false }
        return scalars.allSatisfy { alphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    private static func validate(_ node: HTCondorDAGNode) throws {
        guard isNodeName(node.sample) else {
            throw HTCondorSubmitError.invalidValue(
                field: "sample name",
                rule: "is not a letter or digit followed by at most 63 letters, digits, _ or -, or is a word DAGMan keeps."
            )
        }
        guard node.requestDiskGB >= 1 else {
            throw HTCondorSubmitError.invalidValue(field: "disk request of \(node.sample)", rule: "is under 1 GB.")
        }
        try HTCondorValueRules.checkStagingURL(node.planTarURL, field: "plan tar URL of \(node.sample)")
        guard HTCondorStagedFile(url: node.planTarURL, relativePath: "").transferName == HTCondorSubmitTemplate.planTarName else {
            throw HTCondorSubmitError.invalidValue(
                field: "plan tar URL of \(node.sample)",
                rule: "does not end in \(HTCondorSubmitTemplate.planTarName), the name the job wrapper unpacks."
            )
        }
        guard !node.reads.isEmpty else {
            throw HTCondorSubmitError.invalidValue(field: "read list of \(node.sample)", rule: "is empty.")
        }
        try HTCondorValueRules.checkStagedFiles(node.reads, field: "read")
        if let folder = node.payloadFolder {
            // The names-only rule of every staging path, so the script line holds no space or shell character.
            try HTCondorValueRules.checkStagingURL("file://\(folder)", field: "payload folder of \(node.sample)")
        }
    }
}
