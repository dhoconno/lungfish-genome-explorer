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
/// database copy `shared/<SHA-256>-<file name>`, one copy per SHA-256 for every batch (ARCH-c4r2 Point 2), and each
/// sample's plan tar, reads and payload `batches/<batch>/<sample>/`.
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
    static func url(_ path: String) -> String { "file://\(path)" }
}

/// One file a batch's jobs read from the staging folder: where it goes, its size and SHA-256 as the plan, `staging.json`
/// or the tar states them, and the Mac file to copy there (nil for the image, which is staged already).
package struct ExecutorPlanBatchFile: Codable, Sendable, Equatable {
    package var role: String
    package var sample: String?
    package var stagingPath: String
    package var size: Int64
    package var sha256: String
    package var source: String?
}

/// `staging-files.json` of a submit folder, the list `--format json` prints.
package struct ExecutorPlanBatchFiles: Codable, Sendable, Equatable {
    package static let fileName = "staging-files.json"
    package var schemaVersion = 1
    package var files: [ExecutorPlanBatchFile]
}

/// What a batch writer wrote.
package struct ExecutorPlanBatch: Sendable, Equatable {
    package var folder: URL
    /// Each sample's plan folder name, which is also its DAG node and job log name.
    package var samples: [String]
    package var files: [ExecutorPlanBatchFile]
}

/// A step or a storage route with no plan form in this build (`docs/formats/executor-plan.md`, "Steps"). Each case names
/// what the user can change.
package enum ExecutorPlanNoPlanForm: Error, Equatable, Sendable, LocalizedError {
    case riboDetector
    case unfusedFastp(stepType: String)
    case interleavedToPaired
    case twoFilesWithNoBinning
    case gzipFileWithNoBinning
    case moreThanTwoFiles(count: Int)
    case recipeStep(stepType: String)
    case conversion(from: String, to: String)

    package var errorDescription: String? {
        switch self {
        case .riboDetector:
            return "This recipe removes ribosomal RNA with RiboDetector, which has no plan form in this build, so pass --no-remove-ribosomal-rna or import on this Mac without --write-plan."
        case .unfusedFastp(let stepType):
            return "This recipe runs its fastp step \(stepType) on its own, which has no plan form in this build, so pass --remove-duplicates to run fastp as one fused step or import on this Mac without --write-plan."
        case .interleavedToPaired:
            return "This recipe splits interleaved reads into R1 and R2 files, which has no plan form in this build, so import the sample as R1 and R2 files or import on this Mac without --write-plan."
        case .twoFilesWithNoBinning:
            return "A plan cannot store two read files with no clumping and no quality binning in this build, so choose a --quality-binning scheme or a --clumping-tool, or import on this Mac without --write-plan."
        case .gzipFileWithNoBinning:
            return "A plan cannot keep one gzip file as it is with no clumping and no quality binning in this build, so choose a --quality-binning scheme or a --clumping-tool, or import on this Mac without --write-plan."
        case .moreThanTwoFiles(let count):
            return "A plan takes one or two read files a sample and this sample has \(count), so import its unpaired reads as a sample of their own or import on this Mac without --write-plan."
        case .recipeStep(let stepType):
            return "The recipe step \(stepType) has no plan form in this build, so choose another recipe or import on this Mac without --write-plan."
        case .conversion(let from, let to):
            return "The recipe's conversion from \(from) to \(to) has no plan form in this build, so choose another recipe or import on this Mac without --write-plan."
        }
    }

    /// The refusals a template request meets before planning: more than two files, and each recipe step or conversion
    /// with no plan form, named by its step type.
    package static func check(_ request: ExecutorPlanTemplateRequest) throws {
        if request.inputSuffixes.count > 2 { throw moreThanTwoFiles(count: request.inputSuffixes.count) }
        guard let recipe = request.recipe else { return }
        for planned in try RecipeEngine().plan(recipe: recipe, inputFormat: request.inputFormat) {
            if case .singleStep(let executor, _) = planned, !(executor is any RecipePlannableStep) {
                let stepType = Swift.type(of: executor).typeID
                switch stepType {
                case "ribodetector-filter": throw riboDetector
                case "fastp-trim", "fastp-dedup": throw unfusedFastp(stepType: stepType)
                default: throw recipeStep(stepType: stepType)
                }
            }
            if case .formatConversion(let from, let to) = planned {
                switch (from, to) {
                case (.pairedR1R2, .interleaved), (.merged, .mixed): continue
                case (.interleaved, .pairedR1R2): throw interleavedToPaired
                default: throw conversion(from: from.rawValue, to: to.rawValue)
                }
            }
        }
    }

    /// The storage route `none` with no binning for two files or one gzip file, which the decoder refuses.
    package static func check(_ template: PlanTemplate, request: ExecutorPlanTemplateRequest) throws {
        guard request.storage.requestedClumpingTool == .none, request.storage.qualityBinning == .none,
              let storage = template.steps.first(where: { $0.kind == .storage }) else { return }
        if storage.inputs.count == 2 { throw twoFilesWithNoBinning }
        if storage.inputs.count == 1, storage.inputs[0].hasSuffix(".gz") { throw gzipFileWithNoBinning }
    }
}

/// Writes the submit folder of one CHTC batch (ARCH Q-C4-8): `run.dag`, `sample.sub`, `lge-job.sh`, `logs/`, one plan
/// folder a sample through the folder writer's shared mode, each sample's `plan.tar` under `staging/<sample>/`, and
/// `staging-files.json`, the files the jobs read from the staging folder. It starts no process and opens no connection:
/// the lane copies the files and submits.
package enum ExecutorPlanBatchWriter {
    package static let logsFolderName = "logs"
    package static let tarsFolderName = "staging"
    private static let gib: Int64 = 1_073_741_824

    /// The disk a job asks for when the sample sheet gives no `request_disk`: three times the sample's input bytes,
    /// rounded up to a whole GiB, plus 8 GiB for the image and the work files. A first value for CHTC's review.
    package static func defaultRequestDiskGiB(inputBytes: Int64) -> Int {
        Int((inputBytes * 3 + gib - 1) / gib) + 8
    }

    /// Refuses a batch name or a staging folder that a transfer line of `sample.sub` or `run.dag` cannot hold, before
    /// anything is written. The batch name is the submit folder's name and each folder of the staging path is a name
    /// of letters, digits, `_`, `.` and `-`, the rule `HTCondorValueRules` applies when the template renders. The
    /// real run and `--dry-run` make this one check.
    package static func checkLayout(_ layout: ExecutorPlanStagingLayout) throws {
        guard HTCondorValueRules.isName(layout.batch) else {
            throw ExecutorPlanError(field: "folder", reason: "The submit folder name \(layout.batch) is also the batch's folder name on CHTC, so name it with letters, digits, _, . and - only.")
        }
        do {
            try HTCondorValueRules.checkRelativePath(String(layout.folder.dropFirst()), field: "staging folder")
        } catch {
            throw ExecutorPlanError(field: "stagingFolder", reason: "The staging folder \(layout.folder) is not a path of folder names made of letters, digits, _, . and -, so pass --staging-folder a path made of those.")
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
                throw ExecutorPlanError(field: "sample.sampleName", reason: "The sample \(row.sampleName) takes the folder name \(name), which is not a letter or digit followed by at most 63 letters, digits, _ or -, so rename the sample.")
            }
            names.append(name)
        }
        return names
    }

    @discardableResult
    package static func write(
        _ recipeTemplate: ExecutorPlanTemplate, request: ExecutorPlanTemplateRequest, rows: [ExecutorPlanSampleRow],
        image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout, into folder: URL
    ) throws -> ExecutorPlanBatch {
        let template = recipeTemplate.template
        try ExecutorPlanNoPlanForm.check(template, request: request)
        try checkLayout(layout)
        let names = try folderNames(for: rows)
        let emissions = try rows.map { try recipeTemplate.emission(for: $0) }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else {
            throw ExecutorPlanError(field: "folder", reason: "The submit folder \(folder.lastPathComponent) already exists. A batch is written into a new folder.")
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            return try write(template, sources: recipeTemplate.sources, rows: rows, names: names, emissions: emissions,
                             image: image, layout: layout, into: folder)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    private static func write(
        _ template: PlanTemplate, sources: [String: URL], rows: [ExecutorPlanSampleRow], names: [String],
        emissions: [ExecutorPlanEmission], image: ExecutorPlanImageRecord, layout: ExecutorPlanStagingLayout, into folder: URL
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
        var nodes: [HTCondorDAGNode] = []
        for (index, emission) in emissions.enumerated() {
            let name = names[index]
            let planFolder = folder.appendingPathComponent(name, isDirectory: true)
            try ExecutorPlanFolderWriter.writeShared(emission, image: image.sif, stagedInputs: true, into: planFolder)
            let tarFolder = folder.appendingPathComponent(tarsFolderName).appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: tarFolder, withIntermediateDirectories: true)
            let tar = tarFolder.appendingPathComponent(HTCondorSubmitTemplate.planTarName)
            try DeterministicTarWriter().archive(entries: try tarEntries(of: planFolder), to: tar)
            let tarData = try Data(contentsOf: tar)
            let tarPath = layout.samplePath(name, HTCondorSubmitTemplate.planTarName)
            files.append(ExecutorPlanBatchFile(role: "plan-tar", sample: name, stagingPath: tarPath, size: Int64(tarData.count),
                                               sha256: DeterministicTarWriter.sha256(tarData), source: tar.path))
            var reads: [HTCondorStagedFile] = []
            let inputs = emission.plan.entries.filter { $0.role == .input }
            for (slot, entry) in zip(template.inputs, inputs) {
                let readName = (slot.relativePath as NSString).lastPathComponent
                let path = layout.samplePath(name, readName)
                reads.append(HTCondorStagedFile(url: ExecutorPlanStagingLayout.url(path), relativePath: slot.relativePath))
                files.append(ExecutorPlanBatchFile(role: "input", sample: name, stagingPath: path, size: entry.size,
                                                   sha256: entry.sha256, source: emission.sources[entry.relativePath]?.path))
            }
            let inputBytes = inputs.reduce(Int64(0)) { $0 + $1.size }
            nodes.append(HTCondorDAGNode(
                sample: name, requestDiskGB: rows[index].requestDiskGiB ?? defaultRequestDiskGiB(inputBytes: inputBytes),
                planTarURL: ExecutorPlanStagingLayout.url(tarPath), reads: reads
            ))
        }
        let submit = try HTCondorSubmitTemplate.render(HTCondorSubmitTemplateInput(
            containerImageURL: ExecutorPlanStagingLayout.url(layout.imagePath(image.sif)),
            executor: try staged(shared.first { $0.role == .executor }, layout: layout),
            databases: try shared.filter { $0.role == .database }.map { try staged($0, layout: layout) },
            heapBytes: Int64(template.storage.clumpifyHeapGB) * gib, requestCpus: template.storage.threads,
            payloadRelativePath: ExecutorPlanEmitter.payloadPath,
            payloadStagingFolderURL: ExecutorPlanStagingLayout.url(layout.batchFolder)
        ))
        let dag = try HTCondorDAG.render(nodes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let list = try encoder.encode(ExecutorPlanBatchFiles(files: files)) + Data("\n".utf8)
        try DurableReplace.replace(Data(HTCondorJobWrapper.text.utf8), named: HTCondorJobWrapper.fileName, in: folder)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: folder.appendingPathComponent(HTCondorJobWrapper.fileName).path)
        try DurableReplace.replace(Data(submit.utf8), named: HTCondorSubmitTemplate.fileName, in: folder)
        try DurableReplace.replace(list, named: ExecutorPlanBatchFiles.fileName, in: folder)
        try DurableReplace.replace(Data(dag.utf8), named: HTCondorDAG.fileName, in: folder)
        return ExecutorPlanBatch(folder: folder, samples: names, files: files)
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
