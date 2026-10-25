// ImportFastqPlanOptions.swift - `import fastq --write-plan`: the submit folder of a CHTC batch (CHTC C4 lane F M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishPortable
import LungfishWorkflow

/// The options of `import fastq --write-plan`. With `--write-plan` the command plans the import once for the recipe and
/// writes a CHTC submit folder in place of importing (ARCH Q-C4-8): `run.dag`, `sample.sub`, `lge-job.sh`, `logs/`,
/// one plan folder a sample with its `staging.json`, each sample's `plan.tar` under `staging/` and
/// `staging-files.json`. It starts no process and opens no connection, so a person copies the files and submits.
struct ImportFastqPlanOptions: ParsableArguments {
    @Option(
        name: .customLong("write-plan"),
        help: ArgumentHelp(
            "Write a CHTC submit folder to this new folder in place of importing",
            discussion: "The folder holds run.dag, sample.sub, lge-job.sh, logs/, one plan folder per sample named by "
                + "its sample, each sample's plan.tar under staging/, and staging-files.json, which lists each file the "
                + "jobs read from the staging folder with its size, its SHA-256 and the file on this Mac to copy there. "
                + "No file is imported and nothing is submitted, so --project is not needed. A sample sheet's "
                + "request_disk column gives a sample's disk request in GB.",
            valueName: "folder"
        )
    )
    var writePlan: String?

    @Option(
        name: .customLong("executor-manifest"),
        help: ArgumentHelp(
            "The manifest.json beside the Linux lungfish-executor, which states its SHA-256, size and build",
            discussion: "Required with --write-plan. This build of the app holds no Linux executor yet, so you name "
                + "the manifest of one you built.",
            valueName: "file"
        )
    )
    var executorManifest: String?

    @Option(
        name: .customLong("image"),
        help: ArgumentHelp(
            "The image.json of the container image the jobs run in, which states the image's file name, SHA-256 and "
                + "size and its tool manifest's SHA-256 and size",
            discussion: "Required with --write-plan. This build of the app holds no image record yet, so you name the "
                + "one written when the image was built.",
            valueName: "file"
        )
    )
    var image: String?

    @Option(
        name: .customLong("image-tool-manifest"),
        help: ArgumentHelp(
            "The image's tool manifest, the file image.json pins",
            discussion: "Required with --write-plan. The plan pins each tool it runs from this file.",
            valueName: "file"
        )
    )
    var imageToolManifest: String?

    @Option(
        name: .customLong("staging-folder"),
        help: ArgumentHelp(
            "The absolute path of the group's staging folder on CHTC that the jobs read from",
            discussion: "Required with --write-plan. The image is in images/, each executor and database copy in "
                + "shared/ under a name that starts with its SHA-256, and each sample's plan tar, reads and result in "
                + "batches/<submit folder name>/<sample>/.",
            valueName: "path"
        )
    )
    var stagingFolder: String?

    @Option(
        name: .customLong("plan-database"),
        help: ArgumentHelp(
            "A database a recipe step reads, as <id>=<index file>, for --write-plan",
            discussion: "Repeat it for each database the recipe reads.",
            valueName: "id=file"
        )
    )
    var planDatabases: [String] = []

    var isOn: Bool { writePlan != nil }
}

/// Why `import fastq --write-plan` wrote no folder, in one sentence a user can act on.
struct ImportFastqPlanRefusal: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension ImportCommand.FastqSubcommand {
    /// The `request_disk` column of a sample sheet, in whole GB.
    static let requestDiskColumn = "request_disk"

    /// The deadlines and grace of K4's slice plan, which ran on CHTC.
    static let planDeadlines = ExecutorPlanDeadlines(
        recipeStepSeconds: 14_400, storageSeconds: 14_400, statisticsSeconds: 3_600, graceSeconds: 60
    )

    /// Plans the import once and writes the submit folder. It reads the input files for their SHA-256 and size and
    /// starts no process.
    func writePlanFolder(reporter: ImportFastqReporter) async throws {
        let options = planOptions
        func refuse(_ message: String) -> ExitCode { reporter.fail(message, exitCode: .inputError) }
        guard let folderPath = options.writePlan else { return }
        guard let manifestPath = options.executorManifest, let imagePath = options.image,
              let toolManifestPath = options.imageToolManifest, let staging = options.stagingFolder else {
            throw refuse("--write-plan needs --executor-manifest, --image, --image-tool-manifest and --staging-folder.")
        }
        guard staging.hasPrefix("/") else { throw refuse("--staging-folder must be an absolute path.") }
        guard let threads else { throw refuse("A plan fixes its thread count, so pass --threads with --write-plan.") }
        guard let heapGB = clumpifyHeapGB, heapGB >= 1 else {
            throw refuse("A plan fixes its clumpify heap, so pass --clumpify-heap-gb with --write-plan.")
        }
        // The plan finds its samples by its own detection, so an option that steers the import's detection is refused
        // with its name and never ignored (ARCH 2: one route for both surfaces).
        guard pairing.lowercased() == "auto" else {
            throw refuse("A plan pairs R1 and R2 files by name as --pairing auto does, so drop --pairing or import on this Mac without --write-plan.")
        }
        guard !recursive else {
            throw refuse("A plan reads the files you name or the top level of one folder, so drop --recursive or name the files.")
        }
        guard name == nil else {
            throw refuse("A plan names each sample from its files or its sample sheet, so drop --name.")
        }
        do {
            let rows = try planRows()
            let template = try await planTemplateRequest(
                threads: threads, heapGB: heapGB, manifest: URL(fileURLWithPath: manifestPath),
                toolManifest: URL(fileURLWithPath: toolManifestPath), suffixes: rows.suffixes, format: rows.format
            )
            let image = try Self.readPlanFile(
                at: imagePath, option: "--image",
                expected: "an image.json, so name the image.json written when the image was built"
            ) { try JSONDecoder().decode(ExecutorPlanImageRecord.self, from: $0) }
            guard image.imageManifest == template.imageManifest else {
                throw ImportFastqPlanRefusal(message: "The tool manifest \(toolManifestPath) is not the one \(imagePath) pins, so name the manifest of that image.")
            }
            try ExecutorPlanNoPlanForm.check(template)
            let host = ExecutorPlanHostFacts(physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                                             processorCount: ProcessInfo.processInfo.activeProcessorCount)
            let recipeTemplate = try ExecutorPlanEmitter.template(template, host: host)
            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            let layout = ExecutorPlanStagingLayout(folder: staging, batch: folder.lastPathComponent)
            if dryRun {
                // A dry run makes the refusals of the real run that the inputs and the names alone decide, so it cannot
                // pass where the run would end for a fixed reason.
                try ExecutorPlanNoPlanForm.check(recipeTemplate.template, request: template)
                try ExecutorPlanBatchWriter.checkLayout(layout)
                let names = try ExecutorPlanBatchWriter.folderNames(for: rows.rows)
                for (row, name) in zip(rows.rows, names) {
                    reporter.text("  \(row.sampleName) in folder \(name): \(row.inputs.map(\.url.lastPathComponent).joined(separator: ", "))")
                }
                reporter.text("This was a dry run, so no submit folder was written.")
                reporter.complete(message: "This was a dry run, so no submit folder was written.")
                return
            }
            let batch = try ExecutorPlanBatchWriter.write(
                recipeTemplate, request: template, rows: rows.rows, image: image, layout: layout, into: folder
            )
            reporter.text("Wrote the submit folder \(batch.folder.path) for \(batch.samples.count) sample(s).")
            for file in batch.files {
                reporter.text("  \(file.size) bytes  \(file.stagingPath)" + (file.source.map { "  from \($0)" } ?? ""))
            }
            // Each job's payload upload makes no folder, so the person makes these before the submit (fix G3).
            for made in batch.folders {
                reporter.text("  make the folder \(made.stagingPath) before you submit")
            }
            reporter.completePlan(folder: batch.folder, samples: batch.samples, files: batch.files)
        } catch let refusal as ExitCode {
            throw refusal
        } catch {
            throw refuse((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// One row a sample, from the sample sheet or the detected files, with the input shape every row must share.
    private func planRows() throws -> (rows: [ExecutorPlanSampleRow], suffixes: [String], format: RecipeFileFormat) {
        let pairs: [SamplePair]
        if let samplesheet {
            guard input.isEmpty else { throw ImportFastqPlanRefusal(message: "Pass either FASTQ input paths or --samplesheet, not both.") }
            pairs = try FASTQSampleSheet.parse(url: URL(fileURLWithPath: samplesheet)).samplePairs()
        } else if input.count == 1, (try? URL(fileURLWithPath: input[0]).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            pairs = try FASTQBatchImporter.detectPairsFromDirectory(URL(fileURLWithPath: input[0]))
        } else {
            guard !input.isEmpty else { throw ImportFastqPlanRefusal(message: "At least one input path or --samplesheet is required.") }
            pairs = FASTQBatchImporter.detectingPairs(from: input.map { URL(fileURLWithPath: $0) }).samples
        }
        guard !pairs.isEmpty else { throw ImportFastqPlanRefusal(message: "No FASTQ files were found, so name the read files or a sample sheet.") }
        var rows: [ExecutorPlanSampleRow] = []
        var shape: [String]?
        for pair in pairs {
            let urls = [pair.r1] + [pair.r2, pair.unpaired].compactMap { $0 }
            let suffixes = urls.map { PlanTemplate.fastqSuffix(of: $0.lastPathComponent) }
            if let shape, shape != suffixes {
                throw ImportFastqPlanRefusal(message: "The sample \(pair.sampleName) has files ending \(suffixes.joined(separator: ", ")) and an earlier sample \(shape.joined(separator: ", ")), so run the command once for each set of file endings.")
            }
            shape = suffixes
            var labels = pair.metadata
            let disk = try labels.removeValue(forKey: Self.requestDiskColumn).map { try Self.requestDiskGiB($0, sample: pair.sampleName) }
            rows.append(ExecutorPlanSampleRow(
                sampleName: pair.sampleName, inputs: try urls.map { try ExecutorPlanSourceFile.measuring($0) },
                sampleSheet: labels.keys.sorted().map { PlanKeyValue(key: $0, value: labels[$0] ?? "") }, requestDiskGiB: disk
            ))
        }
        let suffixes = shape ?? []
        return (rows, suffixes, suffixes.count == 1 ? .single : .pairedR1R2)
    }

    static func requestDiskGiB(_ text: String, sample: String) throws -> Int {
        let digits = text.uppercased().hasSuffix("GB") ? String(text.dropLast(2)) : text
        guard let value = Int(digits.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            throw ImportFastqPlanRefusal(message: "The request_disk value \(text) of sample \(sample) is not a whole number of GB, so write it as a number such as 40.")
        }
        return value
    }

    /// Reads the file that `option` names and decodes it, or refuses in one sentence that names the option and says which
    /// file to give. A read or decode error never reaches the user as `Error Domain` or `keyNotFound`.
    private static func readPlanFile<Value>(
        at path: String, option: String, expected: String, _ decode: (Data) throws -> Value
    ) throws -> Value {
        do {
            return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw ImportFastqPlanRefusal(message: "The file \(path) given to \(option) is not \(expected).")
        }
    }

    /// The recipe's half of the plan, from the command's settings, the executor's manifest and the image's tools.
    private func planTemplateRequest(
        threads: Int, heapGB: Int, manifest: URL, toolManifest: URL, suffixes: [String], format: RecipeFileFormat
    ) async throws -> ExecutorPlanTemplateRequest {
        let executor = try Self.readPlanFile(
            at: manifest.path, option: "--executor-manifest",
            expected: "a manifest.json, so name the manifest.json beside the executor you built"
        ) { try JSONDecoder().decode(ExecutorPlanExecutorManifest.self, from: $0) }
        let (manifestBytes, tools) = try Self.readPlanFile(
            at: toolManifest.path, option: "--image-tool-manifest",
            expected: "a tool manifest, so name the tool manifest that image.json pins"
        ) { data in
            let decoded = try ImageToolManifest.decode(data)
            return (data, decoded)
        }
        let pins = Set(tools.tools.map(\.id)).sorted().compactMap { try? tools.pin(forToolID: $0) }
        var recipe: Recipe?
        var recipeFile: ExecutorPlanSourceFile?
        if self.recipe.lowercased() != "none" || !importOptions.switchOptions.isEmpty {
            let resolved = try Self.resolveImportRecipe(named: self.recipe, switchOptions: importOptions.switchOptions)
            guard let newRecipe = resolved.newRecipe else {
                throw ImportFastqPlanRefusal(message: "The recipe \(self.recipe) is a legacy recipe with no plan form, so choose a recipe file such as vsp2.")
            }
            guard let file = RecipeBundleAccessor.recipesDirectoryURL()?.appendingPathComponent("\(newRecipe.id).recipe.json"),
                  FileManager.default.fileExists(atPath: file.path) else {
                throw ImportFastqPlanRefusal(message: "The file of recipe \(newRecipe.id) was not found, so reinstall Lungfish.")
            }
            recipe = newRecipe
            recipeFile = try ExecutorPlanSourceFile.measuring(file)
        }
        let binning: QualityBinningScheme
        let binningSource: ImportSettingSource
        switch qualityBinning?.lowercased() {
        case nil:
            binning = recipe?.qualityBinning ?? FASTQBatchImporter.ImportConfig.commandDefaultQualityBinning
            binningSource = recipe?.qualityBinning == nil ? .default : .recipe
        case "illumina4": (binning, binningSource) = (.illumina4, .option)
        case "eightlevel", "eight_level", "eight-level": (binning, binningSource) = (.eightLevel, .option)
        case "none": (binning, binningSource) = (.none, .option)
        default: throw ImportFastqPlanRefusal(message: "Unknown quality-binning value '\(qualityBinning ?? "")'. Valid: illumina4, eightLevel, none")
        }
        guard let level = CompressionLevel(rawValue: compression.lowercased()) else {
            throw ImportFastqPlanRefusal(message: "Unknown compression '\(compression)'. Valid: fast, balanced, maximum")
        }
        let clumping = noOptimizeStorage ? ClumpingTool.none : try clumpingTool.map(Self.parseClumpingTool) ?? .auto
        var databases: [String: ExecutorPlanDatabaseFile] = [:]
        for value in planOptions.planDatabases {
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw ImportFastqPlanRefusal(message: "The --plan-database value \(value) is not <id>=<index file>, so write it as deacon-panhuman=/path/to/index.")
            }
            databases[parts[0]] = ExecutorPlanDatabaseFile(
                record: try await RecipeDatabaseIdentity().record(databaseID: parts[0], at: URL(fileURLWithPath: parts[1]))
            )
        }
        return ExecutorPlanTemplateRequest(
            inputFormat: format, inputSuffixes: suffixes, platform: platform == "auto" ? nil : platform, recipe: recipe,
            recipeFile: recipeFile,
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: clumping, clumpifyHeapGB: Int(heapGB), threads: threads, compressor: .bgzip,
                qualityBinning: binning, compressionLevel: level.zlValue, threadsSource: .option, clumpifyHeapSource: .option,
                compressorSource: .default, qualityBinningSource: binningSource
            ),
            executorFile: executor.sourceFile(besideManifestAt: manifest), executorBuild: executor.build,
            imageManifest: PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: manifestBytes), size: Int64(manifestBytes.count)),
            imageTools: pins, deadlines: Self.planDeadlines, databases: databases
        )
    }
}

extension ImportFastqReporter {
    /// The `complete` line of a written submit folder: the paths of the submit folder and of each sample's plan folder
    /// as outputs (Q-C4-8), and each file the jobs read from the staging folder as an artifact of kind `staging-<role>`.
    /// The sizes and digests stay in `staging-files.json` and the human text, since a v2 event has no size field.
    func completePlan(folder: URL, samples: [String], files: [ExecutorPlanBatchFile]) {
        guard eventsOn else { return }
        CLIEventEmitter(enabled: true) { printEventLine($0) }.emitComplete(
            outputs: [folder.path] + samples.map { folder.appendingPathComponent($0, isDirectory: true).path },
            artifacts: files.map { CLIEventArtifact(kind: "staging-\($0.role)", path: $0.stagingPath, role: $0.sample) },
            message: "Wrote the submit folder for \(Set(files.compactMap(\.sample)).count) sample(s)"
        )
    }
}
