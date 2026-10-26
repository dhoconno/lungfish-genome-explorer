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
/// one plan folder a sample with its `staging.json` and its `plan.tar`, and `staging-files.json`. It starts no process
/// and opens no connection, so a person copies the files and submits.
struct ImportFastqPlanOptions: ParsableArguments {
    @Option(
        name: .customLong("write-plan"),
        help: ArgumentHelp(
            "Write a plan folder for a run on a Linux machine to this new folder in place of importing",
            discussion: "The folder holds run.dag, sample.sub, lge-job.sh, logs/, one plan folder per sample named by "
                + "its sample with the sample's plan.tar, and staging-files.json, which lists each file the "
                + "jobs read from the staging folder with its size, its SHA-256 and the file on this Mac to copy there, "
                + "or none for a read already in the staging folder. "
                + "jobs.tsv and run-local.sh run the same plans on one Linux machine with Apptainer or Docker, and "
                + "README.txt gives the commands for both and for bringing the results back. "
                + "No file is imported and nothing is submitted, so --project is not needed. A sample sheet's "
                + "request_disk column gives a sample's disk request in GB. With no --clumping-tool, or with "
                + "--clumping-tool auto, the plan clumps every sample of short reads with BBTools clumpify at the "
                + "plan's heap, whatever its size, because clumpify splits a large sample into more groups to fit that "
                + "heap. An import on this Mac with auto does the same at this Mac's clumpify heap. Reads that "
                + "--platform names as ont, pacbio or unknown are not clumped with auto, because clumpify works well "
                + "only on accurate reads. Name --clumping-tool bbtools to clump them. A plan that names no platform "
                + "is planned as short reads.",
            valueName: "folder"
        )
    )
    var writePlan: String?

    @Option(
        name: .customLong("executor-manifest"),
        help: ArgumentHelp(
            "The manifest.json beside the Linux lungfish-executor, which states its SHA-256, size and build",
            discussion: "Optional with --write-plan. The app holds a Linux executor and the plan uses it. Name the "
                + "manifest of one you built to use that one instead.",
            valueName: "file"
        )
    )
    var executorManifest: String?

    @Option(
        name: .customLong("image"),
        help: ArgumentHelp(
            "The image.json of the container image the jobs run in, which states the image's file name, SHA-256 and "
                + "size and its tool manifest's SHA-256 and size",
            discussion: "Optional with --write-plan. The app holds an image record and the plan uses it. Name the "
                + "image.json of another image to use that one instead.",
            valueName: "file"
        )
    )
    var image: String?

    @Option(
        name: .customLong("image-tool-manifest"),
        help: ArgumentHelp(
            "The image's tool manifest, the file image.json pins",
            discussion: "Optional with --write-plan. The plan pins each tool it runs from this file, which the image "
                + "record pins. The app holds the file of its own image record and uses it when you name none.",
            valueName: "file"
        )
    )
    var imageToolManifest: String?

    @Option(
        name: .customLong("staging-folder"),
        help: ArgumentHelp(
            "The absolute path of the folder on the Linux machine that the jobs read the image, the executor and the reads from",
            discussion: "Required with --write-plan. The image is in images/, each executor and database copy in "
                + "shared/ under a name that starts with its SHA-256, each sample's reads in "
                + "batches/<plan folder name>/<sample>/, or where the sample sheet names them when --staged-reads is "
                + "given, and the files its job returns in batches/<plan folder name>/<sample>/result/.",
            valueName: "path"
        )
    )
    var stagingFolder: String?

    /// The list of reads that exist only in the Linux staging folder (C6 ruling STAGED, O59). The help gives the one
    /// portable command that makes the list there, and names no site.
    @Option(
        name: .customLong("staged-reads"),
        help: ArgumentHelp(
            "A tab-separated list of reads already in the staging folder, with each read's absolute path, size in bytes "
                + "and SHA-256, for --write-plan with --samplesheet",
            discussion: "The sample sheet's r1 and r2 then name each read by its absolute path in the staging folder on "
                + "the Linux machine, and Lungfish reads none of the reads. The list's first line names the columns "
                + "file, bytes and sha256, separated by tabs, and each later line gives one read. Each job checks each "
                + "read against its size and SHA-256 before any step runs. Pass --platform with it, since Lungfish "
                + "cannot infer the platform of reads it does not read. Make the list on the Linux machine that holds "
                + "the reads:\n"
                + "printf 'file\\tbytes\\tsha256\\n' > staged-reads.tsv\n"
                + "for f in /absolute/folder/*.fastq.gz; do\n"
                + "printf '%s\\t%s\\t%s\\n' \"$f\" \"$(stat -L -c %s \"$f\")\" \\\n"
                + "\"$(sha256sum \"$f\" | cut -d ' ' -f 1)\" >> staged-reads.tsv\n"
                + "done",
            valueName: "file"
        )
    )
    var stagedReads: String?

    @Option(
        name: .customLong("job-requirements"),
        help: ArgumentHelp(
            "The machines the jobs may run on, as one HTCondor requirements expression, for --write-plan",
            discussion: "It replaces the whole default, which asks for machines that can read the staging folder and "
                + "run an EL9 or later system on an x86-64 CPU. Write it on one line. Leave it out to keep the default.",
            valueName: "expression"
        )
    )
    var jobRequirements: String?

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

/// The files `--write-plan` takes when no option names them: the manifest of the Linux executor the app holds, and the
/// image record with its tool manifest, which ship with the app (C5 lane CMD). A build with no executor folder holds none.
struct ImportFastqPlanDefaults {
    var executorManifest: URL?
    var image: URL?
    var imageToolManifest: URL?

    /// UX-XC26's sentence for a build with no executor, with the option that names one.
    static let noExecutorSentence = "This build of Lungfish has no Linux executor, so it cannot write a plan for a run on another machine. Release builds include it. Pass --executor-manifest to name the manifest of one you built."
    static let noImageSentence = "This build of Lungfish holds no image record, so pass --image to name an image.json and --image-tool-manifest to name the image's image-manifest.json."

    /// The executor and image of the running app. The executor counts only with its file beside the manifest. `locate`
    /// finds a resource by its path below a resource root, and a test gives it a folder of its own.
    static func bundled(
        locate: (String, RuntimeResourceTarget) -> URL? = { RuntimeResourceLocator.path($0, in: $1) }
    ) -> ImportFastqPlanDefaults {
        var executor: URL?
        if let manifest = locate("LinuxExecutor/x86_64/manifest.json", .app) {
            let file = manifest.deletingLastPathComponent().appendingPathComponent(ExecutorPlanExecutorManifest.executorFileName)
            if FileManager.default.isReadableFile(atPath: file.path) { executor = manifest }
        }
        return ImportFastqPlanDefaults(
            executorManifest: executor,
            image: locate("CHTCImage/image.json", .workflow),
            imageToolManifest: locate("CHTCImage/image-manifest.json", .workflow)
        )
    }
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
        guard let staging = options.stagingFolder else { throw refuse("--write-plan needs --staging-folder.") }
        // With no option the plan uses the executor in the app and the image record that ships with it, so a lab member
        // names neither (C5 lane CMD). A build with no executor refuses in UX-XC26's words before it reads any input.
        let files: (executorManifest: String, image: String, imageToolManifest: String)
        do {
            files = try Self.planFiles(options: options, defaults: .bundled())
        } catch {
            throw refuse((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let (manifestPath, imagePath, toolManifestPath) = (files.executorManifest, files.image, files.imageToolManifest)
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
        // Staged reads are paired by the sheet's rows, since this Mac cannot list the staging folder, and their platform
        // is named, since the adopt of a folder with no reads cannot infer it (ruling STAGED points 1 and 5).
        if options.stagedReads != nil {
            guard samplesheet != nil, input.isEmpty else {
                throw refuse("A plan of staged reads takes its samples from a sample sheet, so pass --samplesheet and no input paths.")
            }
            // A name that is no platform is refused too: the adopt reads such a plan as `auto` and, with no R1 to read,
            // refuses every sample after the whole run (review of lane STAGED, Fix 1).
            switch ImportPlatformRequest(cliValue: platform) {
            case .given?:
                break
            case .auto?:
                throw refuse("Lungfish does not read reads in the staging folder, so it cannot infer their platform. Pass --platform, such as --platform illumina.")
            case nil:
                throw refuse("Unknown platform '\(platform)'. Valid: \(ImportPlatformRequest.cliValues.filter { $0 != "auto" }.joined(separator: ", "))")
            }
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let layout = ExecutorPlanStagingLayout(folder: staging, batch: folder.lastPathComponent)
        do {
            let rows = try planRows(layout: layout)
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
            if dryRun {
                // A dry run makes the refusals of the real run that the inputs and the names alone decide, so it cannot
                // pass where the run would end for a fixed reason.
                try ExecutorPlanNoPlanForm.check(recipeTemplate.template, request: template)
                try ExecutorPlanBatchWriter.checkLayout(layout)
                try ExecutorPlanBatchWriter.checkRequirements(options.jobRequirements)
                let names = try ExecutorPlanBatchWriter.folderNames(for: rows.rows)
                for (row, name) in zip(rows.rows, names) {
                    let reads = row.stagedPaths ?? row.inputs.map(\.url.lastPathComponent)
                    reporter.text("  \(row.sampleName) in folder \(name): \(reads.joined(separator: ", "))")
                }
                if let list = options.stagedReads {
                    reporter.text("The reads are in the staging folder already, and each job checks each read against the size and SHA-256 that \(list) gives.")
                }
                reporter.text("This was a dry run, so no plan folder was written.")
                reporter.complete(message: "This was a dry run, so no plan folder was written.")
                return
            }
            let batch = try ExecutorPlanBatchWriter.write(
                recipeTemplate, request: template, rows: rows.rows, image: image, layout: layout,
                requirements: options.jobRequirements, into: folder
            )
            reporter.text("Wrote the plan folder \(batch.folder.path) for \(batch.samples.count) sample(s).")
            for file in batch.files {
                // A staged read has no Mac file, as the image has none, and its line says it is there already (UX 1).
                let from = file.source.map { "  from \($0)" } ?? (file.role == "input" ? "  already in the staging folder" : "")
                reporter.text("  \(file.size) bytes  \(file.stagingPath)" + from)
            }
            // Each job takes its plan tar from the submit folder, so the tar is not copied to the staging folder (C5 D15).
            for tar in batch.planTars {
                reporter.text("  \(tar.size) bytes  \(tar.relativePath) stays in the plan folder, and the job of \(tar.sample) takes it from there")
            }
            // An upload makes no folder, so run.dag makes each folder a job returns files into before it submits the job (fix G3).
            for made in batch.folders {
                reporter.text("  run.dag makes the folder \(made.stagingPath) before it submits the job of \(made.sample)")
            }
            reporter.completePlan(folder: batch.folder, samples: batch.samples, files: batch.files, folders: batch.folders)
        } catch let refusal as ExitCode {
            throw refusal
        } catch {
            throw refuse((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The executor manifest, image record and tool manifest a plan names: the options' own, else the app's.
    static func planFiles(
        options: ImportFastqPlanOptions, defaults: ImportFastqPlanDefaults
    ) throws -> (executorManifest: String, image: String, imageToolManifest: String) {
        guard let manifest = options.executorManifest ?? defaults.executorManifest?.path else {
            throw ImportFastqPlanRefusal(message: ImportFastqPlanDefaults.noExecutorSentence)
        }
        guard let image = options.image ?? defaults.image?.path,
              let toolManifest = options.imageToolManifest ?? defaults.imageToolManifest?.path else {
            throw ImportFastqPlanRefusal(message: ImportFastqPlanDefaults.noImageSentence)
        }
        return (manifest, image, toolManifest)
    }

    /// One row a sample, from the sample sheet or the detected files, with the input shape every row must share. With
    /// `--staged-reads` the list is read first, then each sheet row's reads are checked against `layout` and the list,
    /// and each read's size and SHA-256 come from the list, so no read is opened (ruling STAGED).
    private func planRows(
        layout: ExecutorPlanStagingLayout
    ) throws -> (rows: [ExecutorPlanSampleRow], suffixes: [String], format: RecipeFileFormat) {
        let staged = try planOptions.stagedReads.map { try ImportFastqStagedReads.read($0) }
        let pairs: [SamplePair]
        if let samplesheet {
            guard input.isEmpty else { throw ImportFastqPlanRefusal(message: "Pass either FASTQ input paths or --samplesheet, not both.") }
            let sheet = URL(fileURLWithPath: samplesheet)
            do {
                pairs = try FASTQSampleSheet.parse(url: sheet).samplePairs()
            } catch FASTQSampleSheetError.missingRequiredColumns where Self.firstLineHoldsTabNotComma(sheet) {
                // The batch's sheet stays comma-separated (ARCH-c5 point 8), so a tab-separated one is refused by name.
                throw ImportFastqPlanRefusal(message: "The sample sheet is tab-separated. Write it comma-separated, as samples.csv with sample, r1 and r2 columns.")
            }
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
            let stagedInputs = try staged?.inputs(of: pair, files: urls, layout: layout)
            let suffixes = urls.map { PlanTemplate.fastqSuffix(of: $0.lastPathComponent) }
            if let shape, shape != suffixes {
                throw ImportFastqPlanRefusal(message: "The sample \(pair.sampleName) has files ending \(suffixes.joined(separator: ", ")) and an earlier sample \(shape.joined(separator: ", ")), so run the command once for each set of file endings.")
            }
            shape = suffixes
            var labels = pair.metadata
            let disk = try labels.removeValue(forKey: Self.requestDiskColumn).map { try Self.requestDiskGiB($0, sample: pair.sampleName) }
            rows.append(ExecutorPlanSampleRow(
                sampleName: pair.sampleName, inputs: try stagedInputs ?? urls.map { try ExecutorPlanSourceFile.measuring($0) },
                sampleSheet: labels.keys.sorted().map { PlanKeyValue(key: $0, value: labels[$0] ?? "") }, requestDiskGiB: disk,
                stagedPaths: stagedInputs.map { _ in urls.map(\.path) }
            ))
        }
        let suffixes = shape ?? []
        return (rows, suffixes, suffixes.count == 1 ? .single : .pairedR1R2)
    }

    /// Whether the sheet's first line holds a tab and no comma, which is how a tab-separated sheet begins.
    private static func firstLineHoldsTabNotComma(_ sheet: URL) -> Bool {
        guard let text = try? String(contentsOf: sheet, encoding: .utf8) else { return false }
        let first = text.prefix { $0 != "\n" && $0 != "\r" }
        return first.contains("\t") && !first.contains(",")
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
    /// as outputs (Q-C4-8), each file the jobs read from the staging folder as an artifact of kind `staging-<role>`, and
    /// each folder the jobs write into there as one of kind `staging-result-folder` with the sample as its role, so a
    /// reader of events learns the folders as well as the files. The sizes and digests stay in `staging-files.json` and
    /// the human text, since a v2 event has no size field.
    func completePlan(folder: URL, samples: [String], files: [ExecutorPlanBatchFile], folders: [ExecutorPlanBatchFolder]) {
        guard eventsOn else { return }
        let staged = files.map { CLIEventArtifact(kind: "staging-\($0.role)", path: $0.stagingPath, role: $0.sample) }
        let made = folders.map { CLIEventArtifact(kind: "staging-\($0.role)", path: $0.stagingPath, role: $0.sample) }
        CLIEventEmitter(enabled: true) { printEventLine($0) }.emitComplete(
            outputs: [folder.path] + samples.map { folder.appendingPathComponent($0, isDirectory: true).path },
            artifacts: staged + made,
            message: "Wrote the plan folder for \(Set(files.compactMap(\.sample)).count) sample(s)"
        )
    }
}
