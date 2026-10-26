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

    /// The work root's peak over a sample's input bytes, w, one value a preset (CHTC-3d R4). Wastewater is 10.61, the
    /// larger of SRR24403534's (7,057,265,186 − 3,348,200,894) / 372,364,449 = 9.961 and SRR38262740's
    /// (4,347,450,604 − 3,348,200,894) / 94,232,530 = 10.604, rounded up. VSP2 is 5.03, X3's SRR35520572 node,
    /// (5,463,083,200 − 3,338,092,947) / 422,847,301 = 5.0254, rounded up so the rule never asks less than the node
    /// used. A value rises when a node reads higher and falls only by a panel ruling after CH-10's full-size node.
    package static let workRootFactors: [String: Double] = [
        "vsp2-target-enrichment": 5.03,
        "wastewater-metagenomics": 10.61,
    ]

    /// A preset with no node, or a batch with no preset, takes the largest value.
    package static let largestWorkRootFactor = workRootFactors.values.max() ?? 10.61

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
        var used = Set<String>()
        var names: [String] = []
        for row in rows {
            let name = SampleFolderNaming.uniqueDirectoryName(for: row.sampleName, usedNames: &used)
            used.insert(name)
            guard HTCondorDAG.isNodeName(name) else {
                throw ExecutorPlanError(field: "sample.sampleName", reason: "The sample \(row.sampleName) takes the folder name \(name), which is not an ASCII letter or digit followed by at most 63 ASCII letters, digits, _ or -, or is a word DAGMan keeps, so rename the sample.")
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
        do {
            return try write(template, sources: recipeTemplate.sources, rows: rows, names: names, emissions: emissions,
                             image: image, layout: layout, requirements: requirements,
                             workRootFactor: workRootFactor(forPreset: request.recipe?.resolution?.preset?.id), into: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private static func write(
        _ template: PlanTemplate, sources: [String: URL], rows: [ExecutorPlanSampleRow], names: [String],
        emissions: [ExecutorPlanEmission], image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout,
        requirements: String?, workRootFactor factor: Double, into folder: URL
    ) throws -> ExecutorPlanBatch {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder.appendingPathComponent(logsFolderName), withIntermediateDirectories: false)
        var files = [ExecutorPlanBatchFile(role: "image", sample: nil, stagingPath: layout.imagePath(image.sif),
                                           size: image.sif.size, sha256: image.sif.sha256, source: nil)]
        let shared = template.entries.filter { ExecutorPlanFolderWriter.sharedRoles.contains($0.role) }
        for entry in shared {
            files.append(ExecutorPlanBatchFile(role: entry.role.rawValue, sample: nil, stagingPath: layout.sharedPath(entry),
                                               size: entry.size, sha256: entry.sha256, source: sources[entry.relativePath]?.path))
        }
        let sharedBytes = shared.reduce(Int64(0)) { $0 + $1.size }
        // jobs.tsv names the executor first, then each database, then the reads: the order lge-job.sh takes them.
        let sharedPlacements = (shared.filter { $0.role == .executor } + shared.filter { $0.role == .database })
            .map { "\(layout.pathBelowFolder(layout.sharedPath($0)))=\($0.relativePath)" }
        var jobs: [LinuxRunJob] = []
        // The adopt reads each report in the returned folder at its `work/` path, so the job returns the plan's reports
        // (the recipe outputs no step reads) and no other file of `work/` (AMV2 fix G1), into the sample's result folder.
        let reports = HTCondorSubmitTemplate.reportRelativePaths(of: template.steps)
        let resultFolders = HTCondorSubmitTemplate.resultFolders(
            payloadRelativePath: ExecutorPlanEmitter.payloadPath, reportRelativePaths: reports
        )
        var nodes: [HTCondorDAGNode] = []
        var folders: [ExecutorPlanBatchFolder] = []
        var tars: [ExecutorPlanBatchTar] = []
        for (index, emission) in emissions.enumerated() {
            let name = names[index]
            let made = resultFolders.map { layout.samplePath(name, $0) }
            folders += made.map { ExecutorPlanBatchFolder(role: ExecutorPlanBatchFolder.resultRole, sample: name, stagingPath: $0) }
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
            let inputs = emission.plan.entries.filter { $0.role == .input }
            // A staged read (C6 ruling STAGED) is read where it sits, so it has no Mac file to copy and no sample path.
            let stagedPaths = rows[index].stagedPaths
            for (position, (slot, entry)) in zip(template.inputs, inputs).enumerated() {
                let path = stagedPaths?[position]
                    ?? layout.samplePath(name, (slot.relativePath as NSString).lastPathComponent)
                reads.append(HTCondorStagedFile(url: ExecutorPlanStagingLayout.url(path), relativePath: slot.relativePath))
                placements.append("\(layout.pathBelowFolder(path))=\(slot.relativePath)")
                let source = stagedPaths == nil ? emission.sources[entry.relativePath]?.path : nil
                files.append(ExecutorPlanBatchFile(role: "input", sample: name, stagingPath: path, size: entry.size,
                                                   sha256: entry.sha256, source: source))
            }
            let inputBytes = inputs.reduce(Int64(0)) { $0 + $1.size }
            // The sheet's request_disk column wins over the rule.
            let disk = rows[index].requestDiskGiB ?? requestDiskGiB(
                inputBytes: inputBytes, imageBytes: image.sif.size, planTarBytes: Int64(tarData.count), sharedBytes: sharedBytes,
                workRootFactor: factor
            )
            nodes.append(HTCondorDAGNode(
                sample: name, requestDiskGB: disk, planTarPath: HTCondorSubmitTemplate.planTarName, reads: reads,
                resultFolders: made
            ))
            jobs.append(LinuxRunJob(sample: name, planTarPath: tars[index].relativePath, planTarSHA256: tars[index].sha256,
                                    placements: placements))
        }
        let submit = try HTCondorSubmitTemplate.render(HTCondorSubmitTemplateInput(
            containerImageURL: ExecutorPlanStagingLayout.url(layout.imagePath(image.sif)),
            executor: try staged(shared.first { $0.role == .executor }, layout: layout),
            databases: try shared.filter { $0.role == .database }.map { try staged($0, layout: layout) },
            heapBytes: Int64(template.storage.clumpifyHeapGB) * gib, requestCpus: template.storage.threads,
            payloadRelativePath: ExecutorPlanEmitter.payloadPath,
            resultStagingFolderURL: ExecutorPlanStagingLayout.url(layout.batchFolder),
            reportRelativePaths: reports, requirements: requirements
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
        let resultPaths = HTCondorSubmitTemplate.resultRelativePaths(
            payloadRelativePath: ExecutorPlanEmitter.payloadPath, reportRelativePaths: reports
        )
        let run = LinuxRunScript.text(batch: layout.batch, image: image.sif, resultPaths: resultPaths, maxJobs: concurrentJobs)
        let readme = ExecutorPlanBatchReadme.text(layout: layout, image: image.sif, maxJobs: concurrentJobs,
                                                  stagedReads: rows.contains { $0.stagedPaths != nil })
        try DurableReplace.replace(Data(LinuxRunScript.jobsTable(jobs).utf8), named: LinuxRunScript.jobsFileName, in: folder)
        try DurableReplace.replace(Data(run.utf8), named: LinuxRunScript.fileName, in: folder)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: folder.appendingPathComponent(LinuxRunScript.fileName).path)
        try DurableReplace.replace(Data(readme.utf8), named: ExecutorPlanBatchReadme.fileName, in: folder)
        return ExecutorPlanBatch(folder: folder, samples: names, files: files, folders: folders, planTars: tars)
    }

    private static func staged(_ entry: PlanEntry?, layout: ExecutorPlanStagingLayout) throws -> HTCondorStagedFile {
        guard let entry else {
            throw ExecutorPlanError(field: "entries", reason: "The plan pins no executor, so no job can start it.")
        }
        return HTCondorStagedFile(url: ExecutorPlanStagingLayout.url(layout.sharedPath(entry)), relativePath: entry.relativePath)
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
