// HTCondorSubmitTemplate.swift - The sample.sub of one recipe in a CHTC batch (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// A file a job transfers from the group's staging folder by a `file:///` URL, which the job wrapper then moves to a path
/// inside the unpacked plan folder.
///
/// HTCondor writes a transferred file into the job's scratch folder under the URL's last path component, so that
/// component is the name the wrapper finds it by. The executor and each database are kept once in the staging folder
/// under a name that holds their SHA-256, and every job of a batch transfers the same copy (ARCH-c4r2 Point 2).
public struct HTCondorStagedFile: Sendable, Equatable {
    /// The file on `/staging`, as `file:///staging/...`.
    public var url: String
    /// The plan's `relativePath` for the file, inside the unpacked plan folder.
    public var relativePath: String

    public init(url: String, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }

    /// The URL's last path component, the name HTCondor gives the transferred file.
    public var transferName: String {
        url.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// The wrapper's argument that places this file, `<transfer name>=<relative path>`.
    var placement: String { "\(transferName)=\(relativePath)" }
}

/// Why a submit file or a DAG was not written.
public enum HTCondorSubmitError: Error, Equatable, LocalizedError {
    /// A value holds a character that HTCondor's submit or DAG language, or the wrapper, would read as syntax.
    case invalidValue(field: String, rule: String)
    /// The plan's heap plus the margin asks for more memory than a job of the regular pool may.
    case requestMemoryOverLimit(requestMiB: Int64, limitMiB: Int64)
    /// Two entries would land under one name.
    case duplicate(field: String, name: String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let field, let rule):
            return "The \(field) \(rule)"
        case .requestMemoryOverLimit(let request, let limit):
            let margin = HTCondorSubmitTemplate.memoryMarginBytes >> 20
            return "The job would request \(request) MiB of memory, the plan's heap plus a margin of \(margin) MiB, "
                + "which is over the limit of \(limit) MiB for the regular pool. Lower the recipe's heap."
        case .duplicate(let field, let name):
            return "Two \(field) entries are named \(name)."
        }
    }
}

/// What one recipe's `sample.sub` needs. A plain value that lane F's fill builds from a recipe template (C4 lane F M2).
/// Per-sample values (the sample's name, its plan tar and reads, its disk request) are not here: each DAG node gives them
/// through its `VARS` (``HTCondorDAG``), so every job of a batch shares one submit file.
public struct HTCondorSubmitTemplateInput: Sendable, Equatable {
    /// The image the job runs in, as `file:///staging/...sif`.
    public var containerImageURL: String
    /// The one shared executor copy, placed at the plan's `executor` path and run from there.
    public var executor: HTCondorStagedFile
    /// The shared database copies, each placed at its plan path.
    public var databases: [HTCondorStagedFile]
    /// The plan's JVM heap in bytes, one value for every job of the recipe (C4-04).
    public var heapBytes: Int64
    /// The plan's thread count.
    public var requestCpus: Int
    /// The stored payload's plan path, such as `out/sample.fastq.gz`.
    public var payloadRelativePath: String
    /// The staging folder that receives each sample's payload under `<sample>/<payload path>`, so the payload never
    /// reaches the home submit folder (CHTC-c4r2 4.6).
    public var payloadStagingFolderURL: String
    /// The plan's reports, each a plan path under `work/` such as `work/sample_fused_fastp_report.json`: the recipe
    /// outputs that no later step reads (``HTCondorSubmitTemplate/reportRelativePaths(of:)``). Each one comes home to
    /// the sample's folder at the same path, since the adopt reads it there (``HTCondorSubmitTemplate/render(_:)``).
    /// Nothing else under `work/` comes home. A recipe with no report passes `[]`.
    public var reportRelativePaths: [String]

    public init(
        containerImageURL: String,
        executor: HTCondorStagedFile,
        databases: [HTCondorStagedFile],
        heapBytes: Int64,
        requestCpus: Int,
        payloadRelativePath: String,
        payloadStagingFolderURL: String,
        reportRelativePaths: [String]
    ) {
        self.containerImageURL = containerImageURL
        self.executor = executor
        self.databases = databases
        self.heapBytes = heapBytes
        self.requestCpus = requestCpus
        self.payloadRelativePath = payloadRelativePath
        self.payloadStagingFolderURL = payloadStagingFolderURL
        self.reportRelativePaths = reportRelativePaths
    }
}

/// One `--site-fact` the template asks for: the key the run record keeps and the macro HTCondor expands into its value.
public struct HTCondorSiteFact: Sendable, Equatable {
    public let key: String
    public let macro: String
}

/// The text of one recipe's `sample.sub`.
///
/// The node's facts reach the executor as `--site-fact` arguments that HTCondor expands from the machine ad when the job
/// matches (C4-03, CHTC's FC-A1 ruling). Each machine-ad macro has the default ``unsetValue``, which the wrapper drops,
/// so a fact the slot lacks is not recorded rather than recorded as a false value (C4-02). Only attributes whose values
/// hold no whitespace and no quote are passed, since `condor_submit` drops the single quotes before the schedd splices a
/// value in (CHTC condition 2). The cluster and process ids come from submit macros (Q-C4-10).
public enum HTCondorSubmitTemplate {
    /// The file name lane F's writer gives the template, which every `JOB` line of `run.dag` names.
    public static let fileName = "sample.sub"

    /// The margin for the JVM outside its heap and the compressor children. The first value, from K4's 4 GB heap in a
    /// 12 GB request (`job2-z3.sub:14`). C4-06's job log reading replaces it.
    public static let memoryMarginBytes: Int64 = 8 << 30

    /// The largest request that still matches the regular pool (C4-04).
    public static let requestMemoryLimitBytes: Int64 = 100 << 30

    /// The default of every machine-ad macro. Letters and `_` only, so it passes condition 1's character rule, and the
    /// wrapper drops a fact with this value before it starts the executor.
    public static let unsetValue = "lge_unset"

    /// The machine-ad attributes passed as site facts, each under its own name. Spaced values such as
    /// `ApptainerVersion` and `CondorVersion` wait for a node job that shows a form keeping them one argument.
    public static let machineAdAttributes = [
        "Machine", "Arch", "Microarch", "OpSysAndVer", "OpSysMajorVer", "OSKernelRelease", "Cpus", "Memory", "Disk",
    ]

    /// Every site fact in the order of the `arguments` line.
    public static let siteFacts: [HTCondorSiteFact] =
        machineAdAttributes.map { HTCondorSiteFact(key: $0, macro: "$$(\($0):\(unsetValue))") }
        + [HTCondorSiteFact(key: "ClusterId", macro: "$(Cluster)"), HTCondorSiteFact(key: "ProcId", macro: "$(Process)")]

    /// Staging, an EL9 or later system and x86-64. No `Microarch` clause, since the executor is generic x86-64, and
    /// `Arch` keeps out the pool's one aarch64 host.
    public static let requirements =
        #"(TARGET.HasCHTCStaging == true) && (TARGET.OpSysMajorVer >= 9) && (TARGET.Arch == "X86_64")"#

    /// Up to three retries of a failed (1) or interrupted (3) run. Success, a refusal and a usage error end the job,
    /// since a refusal repeats on every attempt (C4-08). HTCondor reschedules an evicted job on its own.
    public static let maxRetries = 3

    /// The exit codes that end the job with no retry.
    public static let finalExitCodes: [Int32] = [ExecutorExitCode.succeeded, ExecutorExitCode.refused, ExecutorExitCode.usage]

    public static var retryUntil: String {
        finalExitCodes.map { "(ExitCode =?= \($0))" }.joined(separator: " || ")
    }

    /// The signal a vacate or removal sends. The wrapper `exec`s the executor, so it reaches the executor directly.
    public static let killSignal = "SIGTERM"

    /// The folder the plan tar unpacks to in the job's scratch folder.
    public static let planFolderName = "plan"

    /// The plan tar's name in the job's scratch folder. Each sample's tar is staged under this name in its own folder.
    public static let planTarName = "plan.tar"

    /// The job wrapper's file name in the submit folder, beside `run.dag` and one level above each sample's plan folder.
    /// `condor_submit` resolves a relative `executable` against the folder it runs in, never against `initialdir`, so
    /// the template names the wrapper with no `../`.
    public static let wrapperFileName = "lge-job.sh"

    /// The `VARS` names each node of `run.dag` sets. `request_disk` is a GB value that reaches no plan, no argument and
    /// no environment (C4-05, OQ-9 A). The inputs are the sample's plan tar and reads, and the placements the wrapper's
    /// arguments for the reads.
    public static let sampleVariable = "sample"
    public static let requestDiskVariable = "request_disk"
    public static let inputsVariable = "sample_inputs"
    public static let placementsVariable = "sample_placements"

    /// The memory request in MiB: the heap rounded up to a whole MiB plus ``memoryMarginBytes``, at most
    /// ``requestMemoryLimitBytes``. HTCondor reads the `MB` suffix as MiB.
    public static func requestMemoryMiB(heapBytes: Int64) throws -> Int64 {
        guard heapBytes > 0 else {
            throw HTCondorSubmitError.invalidValue(field: "heap", rule: "is not a positive number of bytes.")
        }
        let mebibyte: Int64 = 1 << 20
        let heapMiB = heapBytes / mebibyte + (heapBytes % mebibyte == 0 ? 0 : 1)
        // At most 2^43 MiB, so the sum cannot overflow.
        let request = heapMiB + memoryMarginBytes / mebibyte
        let limit = requestMemoryLimitBytes / mebibyte
        guard request <= limit else {
            throw HTCondorSubmitError.requestMemoryOverLimit(requestMiB: request, limitMiB: limit)
        }
        return request
    }

    /// The plan's reports: the outputs of its recipe steps that no step of the plan reads, in the plan's order, such as
    /// `work/sample_fused_fastp_report.json`. This is the rule the adopt applies to the run record's outputs
    /// (`ExecutorRunAdoption.recordedReports`), so a job returns exactly the files the adopt looks for. The batch writer
    /// passes the result as ``HTCondorSubmitTemplateInput/reportRelativePaths``.
    package static func reportRelativePaths(of steps: [PlanStep]) -> [String] {
        let read = Set(steps.flatMap(\.inputs))
        return steps.filter { $0.kind == .recipe }.flatMap(\.outputs).filter { !read.contains($0) }
    }

    /// The `sample.sub` text.
    ///
    /// The DAG runs it with `initialdir` at the sample's own plan folder, named by the sample, so the run record and the
    /// step logs come home to that folder, where the adopt reads them, and no two jobs write one file. `log`, `output`
    /// and `error` follow `initialdir`, so they name `../logs/`, the submit folder's; `executable` does not.
    public static func render(_ input: HTCondorSubmitTemplateInput) throws -> String {
        try validate(input)
        let memoryMiB = try requestMemoryMiB(heapBytes: input.heapBytes)
        let shared = [input.executor] + input.databases
        let sample = "$(\(sampleVariable))"

        var arguments = shared.map { quoted($0.placement) }
        arguments.append("$(\(placementsVariable))")
        arguments.append(quoted("--"))
        for fact in siteFacts {
            arguments.append(quoted("--site-fact"))
            arguments.append(quoted("\(fact.key)=\(fact.macro)"))
        }
        let inputs = ["$(\(inputsVariable))"] + shared.map(\.url)
        let plan = planFolderName
        // The execute point uploads a file to a `file://` remap only when the remap's key is the path
        // `transfer_output_files` lists it by. A key of the last component sends the payload to the access point, which
        // holds the job at code 12 subcode 1, "Remap of output file resulted in a URL" (fix G3, node job 593391). The
        // upload makes no folder, so the batch writer names the payload's folder to make before the submit.
        let payloadListed = "\(plan)/\(input.payloadRelativePath)"
        // The adopt reads each report in the returned folder at its `work/` path (`ExecutorRunAdoption.recordedReports`), so
        // the job returns each one and never the work folder, which holds the large intermediates. HTCondor names a
        // returned file after the last component of the path it was listed by, so a remap puts each report back.
        try HTCondorValueRules.checkReports(input.reportRelativePaths, payloadRelativePath: input.payloadRelativePath)
        let reports = input.reportRelativePaths
        let outputs = ["\(plan)/run-record.json", "\(plan)/logs", payloadListed] + reports.map { "\(plan)/\($0)" }
        let remaps = ["\(payloadListed) = \(input.payloadStagingFolderURL)/\(sample)/\(input.payloadRelativePath)"]
            + reports.map { "\(HTCondorValueRules.lastComponent($0)) = \($0)" }

        let lines = [
            "# \(fileName) - written by Lungfish for one recipe of a CHTC batch. run.dag gives each job its sample's",
            "# \(sampleVariable), \(requestDiskVariable), \(inputsVariable) and "
                + "\(placementsVariable) through VARS.",
            "universe = container",
            "container_image = \(input.containerImageURL)",
            "initialdir = \(sample)",
            "executable = \(wrapperFileName)",
            "arguments = \"\(arguments.joined(separator: " "))\"",
            "should_transfer_files = YES",
            "when_to_transfer_output = ON_EXIT",
            "transfer_input_files = \(inputs.joined(separator: ", "))",
            "transfer_output_files = \(outputs.joined(separator: ", "))",
            "transfer_output_remaps = \"\(remaps.joined(separator: "; "))\"",
            "requirements = \(requirements)",
            "request_cpus = \(input.requestCpus)",
            "request_memory = \(memoryMiB)MB",
            "request_disk = $(\(requestDiskVariable))",
            "max_retries = \(maxRetries)",
            "retry_until = \(retryUntil)",
            "kill_sig = \(killSignal)",
            "log = ../logs/\(sample).log",
            "output = ../logs/\(sample).out",
            "error = ../logs/\(sample).err",
            "queue",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ argument: String) -> String { "'\(argument)'" }

    private static func validate(_ input: HTCondorSubmitTemplateInput) throws {
        try HTCondorValueRules.checkStagingURL(input.containerImageURL, field: "container image URL")
        try HTCondorValueRules.checkStagingFolderURL(input.payloadStagingFolderURL, field: "payload staging folder URL")
        try HTCondorValueRules.checkRelativePath(input.payloadRelativePath, field: "payload path")
        guard input.requestCpus >= 1 else {
            throw HTCondorSubmitError.invalidValue(field: "CPU count", rule: "is not a whole number of at least 1.")
        }
        try HTCondorValueRules.checkStagedFiles([input.executor] + input.databases, field: "shared file")
    }
}

/// The character rules every value the template and the DAG write must pass, so no value reads as submit, DAG or shell
/// syntax and none splits into two arguments: names of letters, digits, `_`, `.` and `-`.
enum HTCondorValueRules {
    /// Names HTCondor's file transfer or the wrapper's plan unpacking already uses.
    static let reservedTransferNames: Set<String> = [HTCondorSubmitTemplate.planTarName, HTCondorSubmitTemplate.planFolderName]

    static func isName(_ name: String) -> Bool {
        guard (1...255).contains(name.utf8.count), name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_" || scalar == "." || scalar == "-"
        }
    }

    /// The last component of a relative path, the name HTCondor gives a returned file listed by that path.
    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Each report is a path of names under `work/`, and no two returned files share a last component: HTCondor names a
    /// returned file after the last component of the path it was listed by, and only then applies the remap, so two with
    /// one name would overwrite each other. The record, the logs folder and the payload are returned beside the reports.
    static func checkReports(_ reports: [String], payloadRelativePath: String) throws {
        var names: Set<String> = ["run-record.json", "logs", lastComponent(payloadRelativePath)]
        for report in reports {
            try checkRelativePath(report, field: "report path")
            guard report.hasPrefix("work/") else {
                throw HTCondorSubmitError.invalidValue(field: "report path", rule: "is not a path under work/.")
            }
            let name = lastComponent(report)
            guard names.insert(name).inserted else {
                throw HTCondorSubmitError.duplicate(field: "returned file", name: name)
            }
        }
    }

    static func checkRelativePath(_ path: String, field: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 1024, components.allSatisfy({ isName(String($0)) }) else {
            throw HTCondorSubmitError.invalidValue(
                field: field,
                rule: "is not a relative path of names made of letters, digits, _, . and -."
            )
        }
    }

    /// `file:///` and then a path of names, the last one a file.
    static func checkStagingURL(_ url: String, field: String) throws {
        guard url.hasPrefix("file:///"), url.utf8.count <= 4096 else {
            throw HTCondorSubmitError.invalidValue(field: field, rule: "is not a file:/// URL.")
        }
        try checkRelativePath(String(url.dropFirst("file:///".count)), field: field)
    }

    static func checkStagingFolderURL(_ url: String, field: String) throws {
        try checkStagingURL(url, field: field)
    }

    /// Each file's URL and plan path, with no two transfer names or plan paths alike.
    static func checkStagedFiles(_ files: [HTCondorStagedFile], field: String) throws {
        var names = Set<String>()
        var paths = Set<String>()
        for file in files {
            try checkStagingURL(file.url, field: "\(field) URL")
            try checkRelativePath(file.relativePath, field: "\(field) plan path")
            guard !reservedTransferNames.contains(file.transferName) else {
                throw HTCondorSubmitError.invalidValue(
                    field: "\(field) URL",
                    rule: "ends in \(file.transferName), a name the job wrapper keeps for the plan."
                )
            }
            guard names.insert(file.transferName).inserted else {
                throw HTCondorSubmitError.duplicate(field: "\(field) transfer", name: file.transferName)
            }
            guard paths.insert(file.relativePath).inserted else {
                throw HTCondorSubmitError.duplicate(field: "\(field) plan path", name: file.relativePath)
            }
        }
    }
}
