// ExecutorPlanBatchWriter.swift - The submit folder of a CHTC batch: a plan folder a sample, sample.sub and run.dag (CHTC C4 lane F M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishPortable

/// The executor's `manifest.json`, which the packaged app keeps beside the Linux executor (C4 lane B): its SHA-256, its
/// size and the `PlanExecutorBuild` keys at the top level. The plan writer takes these values and never hashes the
/// executor (c3 ARCH 127-130). Until the app holds the file, the caller names one.
package struct ExecutorPlanExecutorManifest: Decodable, Sendable, Equatable {
    package static let executorFileName = "lungfish-executor"

    package var sha256: String
    package var size: Int64
    package var build: PlanExecutorBuild

    private enum CodingKeys: String, CodingKey { case sha256, size }

    package init(sha256: String, size: Int64, build: PlanExecutorBuild) {
        self.sha256 = sha256
        self.size = size
        self.build = build
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try container.decode(String.self, forKey: .sha256)
        size = try container.decode(Int64.self, forKey: .size)
        build = try PlanExecutorBuild(from: decoder)
    }

    /// The executor as the plan pins it: the file beside the manifest, by the manifest's SHA-256 and size.
    package func sourceFile(besideManifestAt manifest: URL) -> ExecutorPlanSourceFile {
        ExecutorPlanSourceFile(
            url: manifest.deletingLastPathComponent().appendingPathComponent(Self.executorFileName), sha256: sha256, size: size
        )
    }
}

/// The image's `image.json` (C4 lane I): the SIF's file name, SHA-256 and size, and the pin of its tool manifest.
package struct ExecutorPlanImageRecord: Decodable, Sendable, Equatable {
    package var schemaVersion: Int
    package var sif: ExecutorPlanImageFile
    package var imageManifest: PlanImageManifestPin

    package init(schemaVersion: Int = 1, sif: ExecutorPlanImageFile, imageManifest: PlanImageManifestPin) {
        self.schemaVersion = schemaVersion
        self.sif = sif
        self.imageManifest = imageManifest
    }
}

/// Where a batch's files sit in the group's staging folder. The image is `images/<file name>`, each executor and
/// database copy `shared/<SHA-256>-<file name>`, one copy per SHA-256 for every batch (ARCH-c4r2 Point 2), each
/// sample's reads `batches/<batch>/<sample>/`, or where the sample sheet names them when `--staged-reads` is given, and
/// its returned files `batches/<batch>/<sample>/result/` (C5 D1).
package struct ExecutorPlanStagingLayout: Sendable, Equatable {
    /// An absolute path, such as `/staging/groups/<group>/<project>/lge-chtc-test`.
    package var folder: String
    /// The batch's name, the submit folder's name.
    package var batch: String

    package init(folder: String, batch: String) {
        self.folder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        self.batch = batch
    }

    package func imagePath(_ image: ExecutorPlanImageFile) -> String { "\(folder)/images/\(image.fileName)" }
    package func sharedPath(_ entry: PlanEntry) -> String {
        "\(folder)/shared/\(entry.sha256)-\((entry.relativePath as NSString).lastPathComponent)"
    }
    package var batchFolder: String { "\(folder)/batches/\(batch)" }
    package func samplePath(_ sample: String, _ name: String) -> String { "\(batchFolder)/\(sample)/\(name)" }
    /// A path this layout gives, below ``folder``, which is how `jobs.tsv` names it below a plain run's data folder.
    package func pathBelowFolder(_ path: String) -> String { String(path.dropFirst(folder.count + 1)) }
    static func url(_ path: String) -> String { "file://\(path)" }
}

/// One file a batch's jobs read from the staging folder: where it goes, its size and SHA-256 as the plan, `staging.json`
/// or the tar states them, and the Mac file to copy there (nil for a file already in the staging folder: the image and
/// staged reads).
package struct ExecutorPlanBatchFile: Codable, Sendable, Equatable {
    package var role: String
    package var sample: String?
    package var stagingPath: String
    package var size: Int64
    package var sha256: String
    package var source: String?
}

/// One folder in the staging folder that a sample's job returns files into: its result folder
/// `batches/<batch>/<sample>/result/` or the folder of one returned file in it, such as `result/out/`. A `file://` upload
/// makes no folder: with none there the job is held at code 12 subcode 256, "Can't open ... for writing" (fix G3, tiny
/// jobs 593396 and 593397). `run.dag` makes a sample's folders with one `SCRIPT PRE` on the access point before it
/// submits the sample's job, so no one makes them by hand, and `staging-files.json` states each as a fact for any reader
/// or other launcher.
package struct ExecutorPlanBatchFolder: Codable, Sendable, Equatable {
    package static let resultRole = "result-folder"
    /// A schema 2 sample's `batches/<batch>/<sample>/staged/` or the folder of one `staged` output in it, which the
    /// job's remap writes into and a later plan reads from (lane EX-SUBMIT).
    package static let stagedRole = "staged-folder"
    package var role: String
    package var sample: String
    package var stagingPath: String
}

/// One sample's plan tar in the submit folder, `<sample>/plan.tar`. The job takes it from there through `initialdir`, so
/// it is no file of the staging folder, and its size and SHA-256 stay pinned here (C5 D15).
package struct ExecutorPlanBatchTar: Sendable, Equatable {
    package var sample: String
    /// The tar's path in the submit folder.
    package var relativePath: String
    package var size: Int64
    package var sha256: String
}

/// `staging-files.json` of a submit folder, the list `--format json` prints: the files to copy to the staging folder
/// and the folders to make there.
package struct ExecutorPlanBatchFiles: Codable, Sendable, Equatable {
    package static let fileName = "staging-files.json"
    package var schemaVersion = 1
    package var files: [ExecutorPlanBatchFile]
    package var folders: [ExecutorPlanBatchFolder]
}

/// What a batch writer wrote.
package struct ExecutorPlanBatch: Sendable, Equatable {
    package var folder: URL
    /// Each sample's plan folder name, which is also its DAG node and job log name.
    package var samples: [String]
    package var files: [ExecutorPlanBatchFile]
    package var folders: [ExecutorPlanBatchFolder]
    /// Each sample's plan tar in the submit folder, in sample order.
    package var planTars: [ExecutorPlanBatchTar]
    /// The words the caller shows for each barcode list the person supplied, where to put it in the staging folder
    /// (``ExecutorPlanFolderWriter/placements(of:shared:)``), then for each index the jobs read where an earlier run left
    /// it, where that is (``ExecutorPlanStagedIndex/placements(of:stagedReferencePaths:layout:)``). A recipe's batch has none.
    package var placements: [String] = []
}

/// One job of a batch (lane EX-SUBMIT): the plan its emitter wrote, with the Mac file of each entry, and the values
/// only the submit side reads. For a schema 2 plan those are the memory in MiB, CPUs and disk in GiB that the emitter's
/// rule sets with the plan, the same numbers its argv holds, never read back from `plan.json` (ruling
/// ARCH-SCHEMA-SPIKE item 4). `stagedPaths` are its reads' absolute paths in the staging folder when they are there
/// already (C6 ruling STAGED), one an input entry in plan order, or nil. `stagedReferencePaths` maps the `relativePath` of
/// each index file that an earlier run left in the staging folder to its absolute path there (``ExecutorPlanStagedIndex``,
/// lane EX-PLAN-STAR), and is empty for a plan that pins no such index.
package struct ExecutorPlanBatchJob: Sendable {
    package var emission: ExecutorPlanEmission
    package var submit: ExecutorPlanSubmitValues
    package var stagedPaths: [String]?
    package var stagedReferencePaths: [String: String]

    package init(
        emission: ExecutorPlanEmission, submit: ExecutorPlanSubmitValues, stagedPaths: [String]? = nil,
        stagedReferencePaths: [String: String] = [:]
    ) {
        self.emission = emission
        self.submit = submit
        self.stagedPaths = stagedPaths
        self.stagedReferencePaths = stagedReferencePaths
    }
}

/// Writes the submit folder of one CHTC batch (ARCH Q-C4-8): `run.dag`, `sample.sub`, `lge-job.sh`, `logs/`, one plan
/// folder a sample through the folder writer's shared mode, each holding its sample's `plan.tar`, and
/// `staging-files.json`, the files the jobs read from the staging folder. Beside them go the plain launcher's `jobs.tsv`
/// and `run-local.sh` (``LinuxRunScript``) and `README.txt` (``ExecutorPlanBatchReadme``) with the lab's commands for
/// both launchers (C5 S2). It starts no process and opens no connection: the lab copies the files and submits.
package enum ExecutorPlanBatchWriter {
    package static let logsFolderName = "logs"
    private static let gib: Int64 = 1_073_741_824

    /// The most jobs of one batch that run at once: `run.dag`'s `MAXJOBS` and the plain launcher's `--jobs`, one value
    /// (C5 D13). A lab batch's job reads about 65 GB from the staging folder, so the batch reads at most ten such at once.
    package static let concurrentJobs = 10

    /// The work root's peak over a sample's input bytes, w, one value a preset (CHTC-3d R4, ruling X6). Wastewater is
    /// 12.14, the largest of five nodes, SRR35904062's (183,159,736,799 − 3,348,200,734) / 14,818,933,598 = 12.134,
    /// rounded up. The others read 9.961 (SRR24403534), 10.604 (SRR38262740), 6.352 (SRR38294966) and 2.409
    /// (SRR38294075), since w follows how much of its reads a sample keeps. VSP2 is 5.03, X3's SRR35520572 node,
    /// (5,463,083,200 − 3,338,092,947) / 422,847,301 = 5.0254, rounded up so the rule never asks less than the node
    /// used. A value rises when a node reads higher and falls only by a panel ruling after CH-10's full-size node.
    package static let workRootFactors: [String: Double] = [
        "vsp2-target-enrichment": 5.03,
        "wastewater-metagenomics": 12.14,
    ]

    /// A preset with no node, or a batch with no preset, takes the largest value.
    package static let largestWorkRootFactor = workRootFactors.values.max() ?? 12.14

    /// The factor of the recipe's resolved preset id.
    package static func workRootFactor(forPreset id: String?) -> Double {
        id.flatMap { workRootFactors[$0] } ?? largestWorkRootFactor
    }

    /// C4's disk rule: three times the sample's input bytes, rounded up to a whole GiB, plus 8 GiB for the image and the
    /// work files.
    package static func defaultRequestDiskGiB(inputBytes: Int64) -> Int {
        Int((inputBytes * 3 + gib - 1) / gib) + 8
    }

    /// The disk a job asks for when the sample sheet gives no `request_disk`, in whole GiB: the larger of C4's rule
    /// (``defaultRequestDiskGiB(inputBytes:)``) and ceil(1.25 × (SIF + 2 × tar + F + w × I) / GiB), where F is the
    /// executor and every database the plan pins, I the sample's input bytes and w ``workRootFactor`` (CHTC-c5 ruling
    /// 3a, C5 D17). Every size is one the plan, the image record or the tar states, and none of it reaches a plan.
    package static func requestDiskGiB(inputBytes: Int64, imageBytes: Int64, planTarBytes: Int64, sharedBytes: Int64,
                                       workRootFactor w: Double = largestWorkRootFactor) -> Int {
        let bytes = Double(imageBytes) + 2 * Double(planTarBytes) + Double(sharedBytes) + w * Double(inputBytes)
        let rule = Int((1.25 * bytes / Double(gib)).rounded(.up))
        return max(defaultRequestDiskGiB(inputBytes: inputBytes), rule)
    }

    /// Refuses a `--job-requirements` value that the one `requirements` line of `sample.sub` cannot hold, before
    /// anything is written. The real run and `--dry-run` make this one check (C5 D9).
    package static func checkRequirements(_ requirements: String?) throws {
        guard let requirements else { return }
        do {
            try HTCondorValueRules.checkRequirements(requirements)
        } catch {
            throw ExecutorPlanError(field: "requirements", reason: "The --job-requirements value is blank, longer than \(HTCondorValueRules.requirementsByteLimit) bytes, or holds a line break, a tab or another control character, so write it as one line.")
        }
    }

    /// Refuses a batch name or a staging folder that a transfer line of `sample.sub` or `run.dag` cannot hold, before
    /// anything is written. The batch name is the submit folder's name and each folder of the staging path is a name
    /// of letters, digits, `_`, `.` and `-`, the rule `HTCondorValueRules` applies when the template renders. The
    /// real run and `--dry-run` make this one check.
    package static func checkLayout(_ layout: ExecutorPlanStagingLayout) throws {
        guard HTCondorValueRules.isName(layout.batch) else {
            throw ExecutorPlanError(field: "folder", reason: "The plan folder name \(layout.batch) is also the batch's folder name in the staging folder, so name it with letters, digits, _, . and - only.")
        }
        do {
            try HTCondorValueRules.checkRelativePath(String(layout.folder.dropFirst()), field: "staging folder")
        } catch {
            throw ExecutorPlanError(field: "stagingFolder", reason: "The staging folder \(layout.folder) is not a path of folder names made of letters, digits, _, . and -, so pass --staging-folder a path made of those.")
        }
    }

    /// Refuses a staged read (C6 ruling STAGED) that is not a file inside the staging folder, whose names below it a
    /// transfer line cannot hold, or that lies in the batch's own folder, where the jobs write, before anything is
    /// written. The writer and `import fastq --staged-reads`, its dry run too, make this one check, so no staged path
    /// reaches ``ExecutorPlanStagingLayout/pathBelowFolder(_:)`` unchecked.
    package static func checkStagedRead(_ path: String, sample: String, layout: ExecutorPlanStagingLayout) throws {
        let prefix = layout.folder + "/"
        let below = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        let names = below.split(separator: "/", omittingEmptySubsequences: false)
        guard !below.isEmpty, !names.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ExecutorPlanError(field: "stagedPaths", reason: "The read \(path) of sample \(sample) is not inside the staging folder \(layout.folder). With --staged-reads every read is a file in the staging folder, named by its absolute path, so plan reads on this Mac in a batch of their own.")
        }
        do {
            try HTCondorValueRules.checkRelativePath(below, field: "staged read")
        } catch {
            throw ExecutorPlanError(field: "stagedPaths", reason: "The read \(path) of sample \(sample) has a name with a character other than letters, digits, _, . and -, which a job's file transfer cannot hold, so rename it.")
        }
        guard !path.hasPrefix(layout.batchFolder + "/") else {
            throw ExecutorPlanError(field: "stagedPaths", reason: "The read \(path) of sample \(sample) is inside the folder \(layout.batchFolder), where this batch's jobs write, so keep the reads outside it.")
        }
    }

    /// Refuses the staging path of an index file that an earlier run left (lane EX-PLAN-STAR) when it is not a file inside
    /// the staging folder, has names below it that a transfer line cannot hold, or lies in the batch's own folder, where
    /// the jobs write. The pin of the index (``ExecutorPlanStagedIndex``) and the batch make this one check.
    package static func checkStagedReference(_ path: String, of relativePath: String, layout: ExecutorPlanStagingLayout) throws {
        let prefix = layout.folder + "/"
        let below = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        let names = below.split(separator: "/", omittingEmptySubsequences: false)
        guard !below.isEmpty, !names.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ExecutorPlanError(field: "stagedReferencePaths", reason: "The index file \(path) is not inside the staging folder \(layout.folder). A job reads an index file where the run that built it left it, so pass --staging-folder the staging folder of that run.")
        }
        do {
            try HTCondorValueRules.checkRelativePath(below, field: "staged index file")
        } catch {
            throw ExecutorPlanError(field: "stagedReferencePaths", reason: "The index file \(path) has a name with a character other than letters, digits, _, . and -, which a job's file transfer cannot hold.")
        }
        guard !path.hasPrefix(layout.batchFolder + "/") else {
            throw ExecutorPlanError(field: "stagedReferencePaths", reason: "The index file \(path) for \(relativePath) is inside the folder \(layout.batchFolder), where this batch's jobs write, so name this batch another folder than the batch that built the index.")
        }
    }

    /// Each staged index path of a job, by ``checkStagedReference(_:of:layout:)``, for a `reference` entry of an index in
    /// its plan.
    private static func checkStagedReferences(_ job: ExecutorPlanBatchJob, layout: ExecutorPlanStagingLayout) throws {
        let plan = job.emission.plan
        for (relativePath, path) in job.stagedReferencePaths.sorted(by: { $0.key < $1.key }) {
            guard plan.entries.contains(where: { $0.role == .reference && $0.relativePath == relativePath && $0.reference?.index != nil }) else {
                throw ExecutorPlanError(field: "stagedReferencePaths", reason: "The job of \(job.submit.sampleName) names a place in the staging folder for \(relativePath), which is no index file of the plan. Only an index file that an earlier run left in the staging folder is read where it sits.")
            }
            try checkStagedReference(path, of: relativePath, layout: layout)
        }
    }

    /// Refuses a sample whose staged reads share a file name. A job takes each file it reads by its name, so two reads of
    /// one name would land on one file in the job's folder.
    package static func checkStagedReadNames(_ paths: [String], sample: String) throws {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        guard let name = names.first(where: { name in names.filter { $0 == name }.count > 1 }) else { return }
        throw ExecutorPlanError(field: "stagedPaths", reason: "The R1 and R2 of sample \(sample) are both named \(name), and a job takes each file by its name, so rename one.")
    }

    /// Each row's staged reads, one path an input, by ``checkStagedRead(_:sample:layout:)`` and
    /// ``checkStagedReadNames(_:sample:)``.
    private static func checkStagedReads(of rows: [ExecutorPlanSampleRow], layout: ExecutorPlanStagingLayout) throws {
        for row in rows {
            guard let paths = row.stagedPaths else { continue }
            guard paths.count == row.inputs.count else {
                throw ExecutorPlanError(field: "stagedPaths", reason: "The sample \(row.sampleName) names \(paths.count) reads in the staging folder for its \(row.inputs.count) input files.")
            }
            for path in paths {
                try checkStagedRead(path, sample: row.sampleName, layout: layout)
            }
            try checkStagedReadNames(paths, sample: row.sampleName)
        }
    }

    /// The folder name of each row, which is also its `staging/` folder, its DAG node and its job log. It is the name
    /// the sample sanitizer gives (`SampleFolderNaming`, which TaxTriage and Viral Recon share), with a suffix when two
    /// samples take one name, and it must be a name the DAG can hold. The real run and `--dry-run` make this one check.
    package static func folderNames(for rows: [ExecutorPlanSampleRow]) throws -> [String] {
        try folderNames(forSamples: rows.map(\.sampleName))
    }

    /// ``folderNames(for:)`` of each job's sample name, which a schema 2 job takes from its submit values.
    package static func folderNames(forSamples samples: [String]) throws -> [String] {
        var used = Set<String>()
        var names: [String] = []
        for sample in samples {
            let name = SampleFolderNaming.uniqueDirectoryName(for: sample, usedNames: &used)
            used.insert(name)
            guard HTCondorDAG.isNodeName(name) else {
                throw ExecutorPlanError(field: "sample.sampleName", reason: "The sample \(sample) takes the folder name \(name), which is not an ASCII letter or digit followed by at most 63 ASCII letters, digits, _ or -, or is a word DAGMan keeps, so rename the sample.")
            }
            names.append(name)
        }
        return names
    }

    /// Writes the submit folder. `requirements`, when given, replaces the whole `requirements` clause of `sample.sub`.
    @discardableResult
    package static func write(
        _ recipeTemplate: ExecutorPlanTemplate, request: ExecutorPlanTemplateRequest, rows: [ExecutorPlanSampleRow],
        image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout, requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        let template = recipeTemplate.template
        try ExecutorPlanNoPlanForm.check(template, request: request)
        try checkLayout(layout)
        try checkRequirements(requirements)
        try checkStagedReads(of: rows, layout: layout)
        let names = try folderNames(for: rows)
        let emissions = try rows.map { try recipeTemplate.emission(for: $0) }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else {
            throw ExecutorPlanError(field: "folder", reason: "The plan folder \(folder.lastPathComponent) already exists, so name a new folder or remove this one.")
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        let jobs = zip(rows, emissions).map { ExecutorPlanBatchJob(emission: $1, submit: $0.split().submit, stagedPaths: $0.stagedPaths) }
        let shape = BatchShape.recipe(heapBytes: Int64(template.storage.clumpifyHeapGB) * gib, cpus: template.storage.threads,
                                      workRootFactor: workRootFactor(forPreset: request.recipe?.resolution?.preset?.id))
        do {
            return try write(jobs, names: names, shape: shape, image: image, layout: layout, requirements: requirements,
                             into: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// Writes the submit folder of a batch of schema 2 plans, each with the submit values its emitter's rule gave
    /// (lane EX-SUBMIT). The jobs share one `sample.sub`, so their plans name the same shared files and return the same
    /// outputs. A schema 2 emitter calls this, or ``dryRun(_:image:layout:requirements:)`` first.
    @discardableResult
    package static func write(
        _ jobs: [ExecutorPlanBatchJob], image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout,
        requirements: String? = nil, into folder: URL
    ) throws -> ExecutorPlanBatch {
        let names = try checkJobs(jobs, image: image, layout: layout, requirements: requirements)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else {
            throw ExecutorPlanError(field: "folder", reason: "The plan folder \(folder.lastPathComponent) already exists, so name a new folder or remove this one.")
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            return try write(jobs, names: names, shape: .eachJob, image: image, layout: layout, requirements: requirements,
                             into: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// The lines a dry run of a schema 2 batch prints after the refusals of the real write: each job's folder and the
    /// memory, CPUs and disk it asks for, then the words for each barcode list the person supplied and for each index
    /// that the jobs read where an earlier run left it.
    package static func dryRun(
        _ jobs: [ExecutorPlanBatchJob], image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout,
        requirements: String? = nil
    ) throws -> [String] {
        let names = try checkJobs(jobs, image: image, layout: layout, requirements: requirements)
        var lines = zip(jobs, names).map { job, name in
            "  \(job.submit.sampleName) in folder \(name) asks for \(job.submit.requestMemoryMiB ?? 0) MiB of memory, "
                + "\(job.submit.requestCpus ?? 0) CPUs and \(job.submit.requestDiskGiB ?? 0) GiB of disk."
        }
        lines += jobs.first.map { ExecutorPlanFolderWriter.placements(of: $0.emission.plan, shared: true) } ?? []
        lines += jobs.first.map {
            ExecutorPlanStagedIndex.placements(of: $0.emission.plan, stagedReferencePaths: $0.stagedReferencePaths, layout: layout)
        } ?? []
        lines.append("This was a dry run, so no plan folder was written.")
        return lines
    }

    /// The refusals of a schema 2 batch before anything is written, and each job's folder name.
    private static func checkJobs(
        _ jobs: [ExecutorPlanBatchJob], image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout, requirements: String?
    ) throws -> [String] {
        try checkLayout(layout)
        try checkRequirements(requirements)
        guard let first = jobs.first?.emission.plan else {
            throw ExecutorPlanError(field: "sample", reason: "The batch holds no plan, so there is no job to write.")
        }
        for job in jobs {
            let plan = job.emission.plan
            let sample = job.submit.sampleName
            guard plan.pipeline != nil else {
                throw ExecutorPlanError(field: "pipeline", reason: "The plan of \(sample) runs no chain of pinned tools (schema 2). A read import writes its plans with import fastq --write-plan.")
            }
            try checkRequest(job.submit)
            guard plan.imageManifest == image.imageManifest else {
                throw ExecutorPlanError(field: "imageManifest", reason: "The plan of \(sample) pins another tool manifest than the image \(image.sif.fileName), so name the image its plan was written for.")
            }
            guard sharedEntries(of: plan) == sharedEntries(of: first), returns(of: plan, shape: .eachJob) == returns(of: first, shape: .eachJob) else {
                throw ExecutorPlanError(field: "entries", reason: "The jobs of one batch share one sample.sub, so each plan names the same executor, databases, references and barcode lists and returns the same outputs. The plan of \(sample) differs from the first, so write it in a batch of its own.")
            }
            guard job.stagedReferencePaths == jobs[0].stagedReferencePaths else {
                throw ExecutorPlanError(field: "stagedReferencePaths", reason: "The jobs of one batch share one sample.sub, so each reads an index that an earlier run left from the same place in the staging folder. The plan of \(sample) reads one from another place than the first, so write it in a batch of its own.")
            }
            try checkStagedReferences(job, layout: layout)
            let inputs = plan.entries.filter { $0.role == .input }.count
            if let paths = job.stagedPaths {
                guard paths.count == inputs else {
                    throw ExecutorPlanError(field: "stagedPaths", reason: "The sample \(sample) names \(paths.count) reads in the staging folder for its \(inputs) input files.")
                }
                for path in paths { try checkStagedRead(path, sample: sample, layout: layout) }
                try checkStagedReadNames(paths, sample: sample)
            }
        }
        return try folderNames(forSamples: jobs.map(\.submit.sampleName))
    }

    /// A schema 2 job's memory, CPUs and disk, which only its emitter's rule knows, each present and within the pool's
    /// bounds: at most ``HTCondorSubmitTemplate/requestMemoryLimitBytes`` of memory and at least 1 CPU.
    private static func checkRequest(_ submit: ExecutorPlanSubmitValues) throws {
        let sample = submit.sampleName
        let missing = [("memory", submit.requestMemoryMiB == nil), ("CPUs", submit.requestCpus == nil), ("disk", submit.requestDiskGiB == nil)]
            .filter(\.1).map(\.0)
        guard missing.isEmpty, let memory = submit.requestMemoryMiB, let cpus = submit.requestCpus, let disk = submit.requestDiskGiB else {
            let named = missing.count > 1 ? missing.dropLast().joined(separator: ", ") + " or " + (missing.last ?? "") : missing.joined()
            throw ExecutorPlanError(field: "request", reason: "The job of \(sample) runs a chain of pinned tools (schema 2) and has no request \(named). The plan's writer sets each such job's memory in MiB, CPUs and disk in GiB, so write the batch through it.")
        }
        let limit = HTCondorSubmitTemplate.requestMemoryLimitBytes >> 20
        guard (1...limit).contains(memory) else {
            throw ExecutorPlanError(field: "request", reason: "The job of \(sample) asks for \(memory) MiB of memory, over the limit of \(limit) MiB for the regular pool or under 1 MiB.")
        }
        guard cpus >= 1 else {
            throw ExecutorPlanError(field: "request", reason: "The job of \(sample) asks for \(cpus) CPUs, and a job asks for at least 1.")
        }
        guard disk >= 1 else {
            throw ExecutorPlanError(field: "request", reason: "The job of \(sample) asks for \(disk) GiB of disk, and a job asks for at least 1 GiB.")
        }
    }

    /// What every job of a batch asks for and returns: a recipe's one heap, threads and work root factor (schema 1), or
    /// each job's own submit values and its plan's `outputPolicy` (schema 2).
    private enum BatchShape {
        case recipe(heapBytes: Int64, cpus: Int, workRootFactor: Double)
        case eachJob
    }

    /// The core of every batch (ruling ARCH-SCHEMA-SPIKE section A item 1): the plans as emitted, each with its submit
    /// values, into one submit folder. A recipe's front and ``write(_:image:layout:requirements:into:)`` both end here.
    private static func write(
        _ batchJobs: [ExecutorPlanBatchJob], names: [String], shape: BatchShape, image: ExecutorPlanImageRecord,
        layout: ExecutorPlanStagingLayout, requirements: String?, into folder: URL
    ) throws -> ExecutorPlanBatch {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder.appendingPathComponent(logsFolderName), withIntermediateDirectories: false)
        guard let first = batchJobs.first?.emission else {
            throw HTCondorSubmitError.invalidValue(field: "sample list", rule: "is empty.")
        }
        var files = [ExecutorPlanBatchFile(role: "image", sample: nil, stagingPath: layout.imagePath(image.sif),
                                           size: image.sif.size, sha256: image.sif.sha256, source: nil)]
        let shared = sharedEntries(of: first.plan)
        // An index file an earlier run left is read where it sits, as a staged read is, and never from shared/ (lane
        // EX-PLAN-STAR). Every job reads it from one place, which checkJobs holds.
        let stagedReferences = batchJobs[0].stagedReferencePaths
        let sharedPaths = shared.map { stagedReferences[$0.relativePath] ?? layout.sharedPath($0) }
        for (entry, path) in zip(shared, sharedPaths) {
            // A list the person supplied has no source: LGE never copies its bytes (BIO-NOTHOST-BARCODE Q2). Nor has an
            // index file an earlier run left, which is in the staging folder already.
            let source = stagedReferences[entry.relativePath] == nil ? first.sources[entry.relativePath]?.path : nil
            files.append(ExecutorPlanBatchFile(role: entry.role.rawValue, sample: nil, stagingPath: path,
                                               size: entry.size, sha256: entry.sha256, source: source))
        }
        let sharedBytes = shared.reduce(Int64(0)) { $0 + $1.size }
        // jobs.tsv names the shared files in the order lge-job.sh takes them, the executor first, then the reads.
        let sharedPlacements = zip(shared, sharedPaths).map { "\(layout.pathBelowFolder($1))=\($0.relativePath)" }
        var jobs: [LinuxRunJob] = []
        let returns = self.returns(of: first.plan, shape: shape)
        let resultPaths: [String]
        let resultFolders: [String]
        var stagedFolders: [String] = []
        var stagedPaths: [String]?
        switch returns {
        case .payload(let payload, let reports):
            // The adopt reads each report in the returned folder at its `work/` path, so the job returns the plan's
            // reports (the recipe outputs no step reads) and no other file of `work/` (AMV2 fix G1), into the sample's
            // result folder.
            resultPaths = HTCondorSubmitTemplate.resultRelativePaths(payloadRelativePath: payload, reportRelativePaths: reports)
            resultFolders = HTCondorSubmitTemplate.resultFolders(payloadRelativePath: payload, reportRelativePaths: reports)
        case .outputs(let home, let staged):
            resultPaths = [HTCondorSubmitTemplate.runRecordName] + home
            resultFolders = HTCondorSubmitTemplate.uploadFolders(of: resultPaths, into: HTCondorSubmitTemplate.resultFolderName)
            stagedPaths = staged
            if !staged.isEmpty {
                stagedFolders = HTCondorSubmitTemplate.uploadFolders(of: staged, into: HTCondorSubmitTemplate.stagedFolderName)
            }
        }
        var nodes: [HTCondorDAGNode] = []
        var folders: [ExecutorPlanBatchFolder] = []
        var tars: [ExecutorPlanBatchTar] = []
        for (index, job) in batchJobs.enumerated() {
            let name = names[index]
            let emission = job.emission
            let made = resultFolders.map { layout.samplePath(name, $0) }
            folders += made.map { ExecutorPlanBatchFolder(role: ExecutorPlanBatchFolder.resultRole, sample: name, stagingPath: $0) }
            let kept = stagedFolders.map { layout.samplePath(name, $0) }
            folders += kept.map { ExecutorPlanBatchFolder(role: ExecutorPlanBatchFolder.stagedRole, sample: name, stagingPath: $0) }
            let planFolder = folder.appendingPathComponent(name, isDirectory: true)
            try ExecutorPlanFolderWriter.writeShared(emission, image: image.sif, stagedInputs: true, into: planFolder)
            // The tar holds the plan folder as written, so its entries are read before the tar is written beside them.
            let entries = try tarEntries(of: planFolder)
            let tar = planFolder.appendingPathComponent(HTCondorSubmitTemplate.planTarName)
            try DeterministicTarWriter().archive(entries: entries, to: tar)
            let tarData = try Data(contentsOf: tar)
            tars.append(ExecutorPlanBatchTar(sample: name, relativePath: "\(name)/\(HTCondorSubmitTemplate.planTarName)",
                                             size: Int64(tarData.count), sha256: DeterministicTarWriter.sha256(tarData)))
            var reads: [HTCondorStagedFile] = []
            var placements = sharedPlacements
            // The fill names each input entry by its slot's path, so the entry's path is the slot's.
            let inputs = emission.plan.entries.filter { $0.role == .input }
            // A staged read (C6 ruling STAGED) is read where it sits, so it has no Mac file to copy and no sample path.
            for (position, entry) in inputs.enumerated() {
                let path = job.stagedPaths?[position]
                    ?? layout.samplePath(name, (entry.relativePath as NSString).lastPathComponent)
                reads.append(HTCondorStagedFile(url: ExecutorPlanStagingLayout.url(path), relativePath: entry.relativePath))
                placements.append("\(layout.pathBelowFolder(path))=\(entry.relativePath)")
                let source = job.stagedPaths == nil ? emission.sources[entry.relativePath]?.path : nil
                files.append(ExecutorPlanBatchFile(role: "input", sample: name, stagingPath: path, size: entry.size,
                                                   sha256: entry.sha256, source: source))
            }
            let inputBytes = inputs.reduce(Int64(0)) { $0 + $1.size }
            let disk: Int
            switch shape {
            case .recipe(_, _, let factor):
                // The sheet's request_disk column wins over the rule.
                disk = job.submit.requestDiskGiB ?? requestDiskGiB(
                    inputBytes: inputBytes, imageBytes: image.sif.size, planTarBytes: Int64(tarData.count), sharedBytes: sharedBytes,
                    workRootFactor: factor
                )
            case .eachJob:
                disk = job.submit.requestDiskGiB ?? 0
            }
            // A schema 2 job's memory and CPUs reach its VARS, whether or not its plan has a `staged` output: the shape of
            // the batch decides it, since sample.sub reads both from VARS for every schema 2 node. A recipe's job asks the one
            // value of sample.sub and its node carries neither.
            let ownRequests: Bool
            if case .eachJob = shape { ownRequests = true } else { ownRequests = false }
            nodes.append(HTCondorDAGNode(
                sample: name, requestDiskGB: disk, planTarPath: HTCondorSubmitTemplate.planTarName, reads: reads,
                resultFolders: made + kept,
                requestMemoryMiB: ownRequests ? job.submit.requestMemoryMiB : nil,
                requestCpus: ownRequests ? job.submit.requestCpus : nil
            ))
            jobs.append(LinuxRunJob(sample: name, planTarPath: tars[index].relativePath, planTarSHA256: tars[index].sha256,
                                    placements: placements))
        }
        guard shared.first?.role == .executor else {
            throw ExecutorPlanError(field: "entries", reason: "The plan pins no executor, so no job can start it.")
        }
        let requests: HTCondorJobRequests
        switch shape {
        case .recipe(let heapBytes, let cpus, _): requests = .recipe(heapBytes: heapBytes, cpus: cpus)
        case .eachJob: requests = .eachJob
        }
        let submit = try HTCondorSubmitTemplate.render(HTCondorSubmitTemplateInput(
            containerImageURL: ExecutorPlanStagingLayout.url(layout.imagePath(image.sif)),
            shared: zip(shared, sharedPaths).map { HTCondorStagedFile(url: ExecutorPlanStagingLayout.url($1), relativePath: $0.relativePath) },
            requests: requests, returns: returns,
            resultStagingFolderURL: ExecutorPlanStagingLayout.url(layout.batchFolder), requirements: requirements
        ))
        let dag = try HTCondorDAG.render(nodes, maxJobs: concurrentJobs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let list = try encoder.encode(ExecutorPlanBatchFiles(files: files, folders: folders)) + Data("\n".utf8)
        try DurableReplace.replace(Data(HTCondorJobWrapper.text.utf8), named: HTCondorJobWrapper.fileName, in: folder)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: folder.appendingPathComponent(HTCondorJobWrapper.fileName).path)
        try DurableReplace.replace(Data(submit.utf8), named: HTCondorSubmitTemplate.fileName, in: folder)
        try DurableReplace.replace(list, named: ExecutorPlanBatchFiles.fileName, in: folder)
        try DurableReplace.replace(Data(dag.utf8), named: HTCondorDAG.fileName, in: folder)
        // The plain launcher returns the same files into result/ as the remaps, and takes run.dag's MAXJOBS as its
        // --jobs default (C5 D13).
        let run = LinuxRunScript.text(batch: layout.batch, image: image.sif, resultPaths: resultPaths, stagedPaths: stagedPaths,
                                      maxJobs: concurrentJobs)
        let placementWords = ExecutorPlanFolderWriter.placements(of: first.plan, shared: true)
        let indexWords = ExecutorPlanStagedIndex.placements(of: first.plan, stagedReferencePaths: stagedReferences, layout: layout)
        var readme: String
        switch returns {
        case .payload:
            readme = ExecutorPlanBatchReadme.text(layout: layout, image: image.sif, maxJobs: concurrentJobs,
                                                  stagedReads: batchJobs.contains { $0.stagedPaths != nil })
        case .outputs(let home, let staged):
            readme = ExecutorPlanBatchReadme.schemaTwoText(layout: layout, image: image.sif, maxJobs: concurrentJobs, home: home,
                                                           staged: staged, placements: placementWords)
        }
        if !indexWords.isEmpty {
            readme += "\n\nIndex files read where an earlier run left them\n\n" + indexWords.joined(separator: "\n\n") + "\n\n"
                + "staging-files.json lists each of these files with no source, since it is in the staging folder already, so\n"
                + "nothing copies it to an HTCondor pool. For a run on one machine, copy or link each into the data folder at\n"
                + "the path above, from the staging folder or from <sample>/staged/ that \(LinuxRunScript.fileName) of the\n"
                + "batch that built the index left.\n"
        }
        try DurableReplace.replace(Data(LinuxRunScript.jobsTable(jobs).utf8), named: LinuxRunScript.jobsFileName, in: folder)
        try DurableReplace.replace(Data(run.utf8), named: LinuxRunScript.fileName, in: folder)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: folder.appendingPathComponent(LinuxRunScript.fileName).path)
        try DurableReplace.replace(Data(readme.utf8), named: ExecutorPlanBatchReadme.fileName, in: folder)
        return ExecutorPlanBatch(folder: folder, samples: names, files: files, folders: folders, planTars: tars,
                                 placements: placementWords + indexWords)
    }

    /// The entries every job of a batch reads from the staging folder's `shared/`, in the order the job wrapper places
    /// them: the executor, which it starts, then each database, reference and supplied barcode list, each role in plan
    /// order (ruling ARCH-SCHEMA-SPIKE section A item 2). A list from the image is never placed, since the executor
    /// copies it from the image.
    static func sharedEntries(of plan: ExecutionPlan) -> [PlanEntry] {
        let roles: [PlanEntryRole] = [.executor, .database, .reference]
        return roles.flatMap { role in plan.entries.filter { $0.role == role } } + plan.entries.filter(\.isSuppliedBarcodeList)
    }

    /// What a job returns: a recipe's payload and reports, or a schema 2 plan's `home` and `staged` outputs in step
    /// order, by each step's `outputPolicy`.
    private static func returns(of plan: ExecutionPlan, shape: BatchShape) -> HTCondorJobReturns {
        guard case .eachJob = shape else {
            return .payload(ExecutorPlanEmitter.payloadPath, reports: HTCondorSubmitTemplate.reportRelativePaths(of: plan.steps))
        }
        func outputs(_ policy: PlanOutputPolicy) -> [String] {
            plan.steps.flatMap { step in step.outputs.filter { step.outputPolicy?[$0] == policy } }
        }
        return .outputs(home: outputs(.home), staged: outputs(.staged))
    }

    /// Every regular file of a plan folder under `plan/`, the folder the job wrapper unpacks.
    private static func tarEntries(of planFolder: URL) throws -> [DeterministicTarEntry] {
        let base = planFolder.resolvingSymlinksInPath().path + "/"
        guard let walk = FileManager.default.enumerator(at: planFolder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var entries: [DeterministicTarEntry] = []
        for case let file as URL in walk where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = file.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
            entries.append(DeterministicTarEntry(path: "\(HTCondorSubmitTemplate.planFolderName)/\(relative)",
                                                 data: try Data(contentsOf: file)))
        }
        return entries.sorted { $0.path < $1.path }
    }
}
