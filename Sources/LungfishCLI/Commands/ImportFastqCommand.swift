// ImportFastqCommand.swift - CLI subcommand for batch FASTQ import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

protocol ManagedDatabaseProvisioning: Sendable {
    func requiredDatabaseManifest(for id: String) async -> BundledDatabase?
    func isDatabaseInstalled(_ id: String) async -> Bool
    func installManagedDatabase(
        _ id: String,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL
}

extension DatabaseRegistry: ManagedDatabaseProvisioning {}

struct ImportFastqCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-fastq",
        abstract: "Batch-import sequencing reads into a Lungfish project"
    )

    @OptionGroup var command: ImportCommand.FastqSubcommand

    func run() async throws {
        try await command.run()
    }
}

// MARK: - FASTQ Import Subcommand

extension ImportCommand {

    /// Import a directory of FASTQ files (or explicit file paths) into a Lungfish project.
    ///
    /// Detects R1/R2 pairs automatically, optionally applies a processing recipe,
    /// and streams structured JSON log events to stdout during import.
    ///
    /// ## Examples
    ///
    /// ```
    /// # Import all .fastq.gz files from a directory
    /// lungfish import fastq /data/sequencing_run/ --project ./MyProject.lungfish
    ///
    /// # Dry-run to preview detected pairs
    /// lungfish import fastq /data/sequencing_run/ --project ./MyProject.lungfish --dry-run
    ///
    /// # Apply vsp2 recipe with 8 threads
    /// lungfish import fastq /data/run/ --project ./MyProject.lungfish --recipe vsp2 --threads 8
    /// ```
    struct FastqSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fastq",
            abstract: "Batch-import FASTQ files or unmapped ONT BAM into a Lungfish project"
        )

        @Argument(help: "Directory containing sequencing reads, FASTQ paths, or unmapped ONT BAM paths")
        var input: [String] = []

        @Option(
            name: .customLong("samplesheet"),
            help: "CSV sample sheet with sample,r1,r2 columns and optional metadata columns"
        )
        var samplesheet: String?

        @Option(
            name: [.customLong("project"), .customShort("p")],
            help: "Path to .lungfish project directory"
        )
        var project: String

        @Option(
            name: .customLong("recipe"),
            help: ArgumentHelp(
                "Processing recipe: \(recipeHelpNames()), or none",
                discussion: recipeHelpDiscussion()
            )
        )
        var recipe: String = "none"

        @Option(
            name: .customLong("quality-binning"),
            help: "Quality binning: illumina4 (7 quality levels), eightLevel (~21 quality levels), none (default: none). Binning is lossy and irreversible once originals are removed — opt in explicitly."
        )
        var qualityBinning: String = "none"

        @Option(
            name: .customLong("log-dir"),
            help: "Directory for per-sample log files"
        )
        var logDir: String?

        @Flag(
            name: .customLong("dry-run"),
            help: "List detected pairs without importing"
        )
        var dryRun: Bool = false

        @Option(
            name: .customLong("platform"),
            help: ArgumentHelp(
                "Sequencing platform: auto, illumina, ont, pacbio, element, mgi, ultima, unknown",
                discussion: """
                auto infers each sample's platform from its read headers (and a BAM \
                file's @RG PL) and prints the evidence. Reads whose platform cannot \
                be inferred are recorded as unknown, never as Illumina. A given value \
                is recorded as given, even when the reads suggest another platform.
                """
            )
        )
        var platform: String = "auto"

        @Option(
            name: .customLong("pairing"),
            help: ArgumentHelp(
                "Read pairing: auto, single, paired, interleaved (default: auto)",
                discussion: """
                auto and paired match R1/R2 files by name. They also join a run's file \
                named for the run alone, such as SRR1.fastq beside SRR1_1.fastq and \
                SRR1_2.fastq, to that pair as unpaired reads, when the first reads of \
                the pair are named as mates and the first read of that file is not one \
                of them. Otherwise the file stays a sample of its own and a warning says \
                why. For any other file with no mate file, they read its records and \
                record interleaved mates when every record is followed by its mate, \
                otherwise single-end. single imports every file as its own single-end \
                sample, even when a mate is detected. interleaved imports every file on \
                its own and records it as interleaved mates.
                """
            )
        )
        var pairing: String = "auto"

        @Flag(
            name: .customLong("no-optimize-storage"),
            help: "Skip read reordering for storage optimization"
        )
        var noOptimizeStorage: Bool = false

        @Option(
            name: .customLong("clumping-tool"),
            help: "Storage optimization tool: auto, bbtools, trim-galore, none (default: platform-specific)"
        )
        var clumpingTool: String?

        @Option(
            name: .customLong("compression"),
            help: "Compression level: fast, balanced, maximum (default: balanced)"
        )
        var compression: String = "balanced"

        @Flag(
            name: .customLong("force"),
            help: "Reimport samples even if bundle already exists"
        )
        var force: Bool = false

        @Option(
            name: .customLong("name"),
            help: "Override the output bundle name. Only valid when exactly one sample is detected."
        )
        var name: String?

        @Flag(
            name: .customLong("recursive"),
            help: "Recursively scan directories for FASTQ files"
        )
        var recursive: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        /// Thread count sourced from the shared `--threads` / `-t` global option.
        var threads: Int? { globalOptions.threads }

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            guard !input.isEmpty || samplesheet != nil else {
                print(formatter.error("At least one input path or --samplesheet is required."))
                throw CLIExitCode.inputError.exitCode
            }
            guard !(samplesheet != nil && !input.isEmpty) else {
                print(formatter.error("Pass either FASTQ input paths or --samplesheet, not both."))
                throw CLIExitCode.inputError.exitCode
            }

            // MARK: Detect pairs

            let detectedPairs: [SamplePair]
            let fm = FileManager.default

            if let samplesheet {
                let sheetURL = URL(fileURLWithPath: samplesheet)
                guard fm.fileExists(atPath: sheetURL.path) else {
                    print(formatter.error("Sample sheet not found: \(samplesheet)"))
                    throw CLIExitCode.inputError.exitCode
                }
                do {
                    detectedPairs = try FASTQSampleSheet.parse(url: sheetURL).samplePairs()
                } catch {
                    print(formatter.error("Could not parse sample sheet: \(error.localizedDescription)"))
                    throw CLIExitCode.formatError.exitCode
                }
            } else if input.count == 1 {
                // Single argument: could be a directory or a single file
                let inputURL = URL(fileURLWithPath: input[0])
                var isDirectory: ObjCBool = false
                let exists = fm.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)

                if exists && isDirectory.boolValue {
                    do {
                        if recursive {
                            detectedPairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(inputURL)
                        } else {
                            detectedPairs = try FASTQBatchImporter.detectPairsFromDirectory(inputURL)
                        }
                    } catch let batchError as BatchImportError {
                        print(formatter.error(batchError.errorDescription ?? batchError.localizedDescription))
                        throw CLIExitCode.inputError.exitCode
                    }
                } else {
                    guard exists else {
                        print(formatter.error("Input not found: \(input[0])"))
                        throw CLIExitCode.inputError.exitCode
                    }
                    detectedPairs = FASTQBatchImporter.detectPairs(from: [inputURL])
                }
            } else {
                // Multiple arguments: treat as explicit file paths
                var fileURLs: [URL] = []
                for path in input {
                    let url = URL(fileURLWithPath: path)
                    guard fm.fileExists(atPath: url.path) else {
                        print(formatter.error("Input file not found: \(path)"))
                        throw CLIExitCode.inputError.exitCode
                    }
                    fileURLs.append(url)
                }
                detectedPairs = FASTQBatchImporter.detectPairs(from: fileURLs)
            }

            // MARK: Apply --pairing

            guard let pairingChoice = FASTQBatchImporter.ImportPairing(rawValue: pairing.lowercased()) else {
                print(formatter.error("Unknown pairing value '\(pairing)'. Valid: auto, single, paired, interleaved"))
                throw CLIExitCode.inputError.exitCode
            }
            // A run's third file stays joined to its pair only when the first
            // reads bear the join out. Otherwise the two are separate samples,
            // as before the join, and a warning says why. The window runs this
            // command with --format json, so its Operations row logs the notice.
            let unpairedReadsCheck = FASTQBatchImporter.checkingUnpairedReads(
                FASTQBatchImporter.applyPairing(pairingChoice, to: detectedPairs)
            )
            let pairs = unpairedReadsCheck.samples
            let isJSON = globalOptions.outputFormat == .json
            let printUnpairedReadsWarnings = {
                for case .notice(let sample, let message) in unpairedReadsCheck.warnings {
                    print(isJSON
                        ? FASTQBatchImporter.encodeLogEvent(.notice(sample: sample, message: message))
                        : formatter.warning("\(sample): \(message)"))
                }
            }

            // MARK: Apply --name override

            let effectivePairs: [SamplePair]
            if let name {
                guard pairs.count == 1 else {
                    printUnpairedReadsWarnings()
                    print(formatter.error("--name requires exactly one detected sample (found \(pairs.count))."))
                    throw CLIExitCode.inputError.exitCode
                }
                let original = pairs[0]
                effectivePairs = [
                    SamplePair(
                        sampleName: name,
                        r1: original.r1,
                        r2: original.r2,
                        unpaired: original.unpaired,
                        relativePath: original.relativePath,
                        metadata: original.metadata,
                        sampleSheetURL: original.sampleSheetURL
                    )
                ]
            } else {
                effectivePairs = pairs
            }

            // MARK: Print detected pairs

            print(formatter.header("FASTQ Import"))
            print("")
            print(formatter.info("Detected \(effectivePairs.count) sample(s):"))
            for (i, pair) in effectivePairs.enumerated() {
                let index = String(format: "%3d", i + 1)
                if let r2 = pair.r2 {
                    print("  \(index). \(pair.sampleName)  [paired]")
                    print("        R1: \(pair.r1.lastPathComponent)")
                    print("        R2: \(r2.lastPathComponent)")
                    if let unpaired = pair.unpaired {
                        print("        Unpaired: \(unpaired.lastPathComponent)")
                    }
                } else {
                    print("  \(index). \(pair.sampleName)  [single-end]")
                    print("        R1: \(pair.r1.lastPathComponent)")
                }
            }
            print("")
            if !unpairedReadsCheck.warnings.isEmpty {
                printUnpairedReadsWarnings()
                print("")
            }

            // MARK: Resolve platform request

            guard let platformRequest = ImportPlatformRequest(cliValue: platform) else {
                print(formatter.error(
                    "Unknown platform '\(platform)'. Valid: \(ImportPlatformRequest.cliValues.joined(separator: ", "))"
                ))
                throw CLIExitCode.inputError.exitCode
            }

            // MARK: Dry-run exit

            if dryRun {
                for pair in effectivePairs {
                    let resolution = FASTQBatchImporter.resolvePlatform(for: pair, request: platformRequest)
                    print("  \(pair.sampleName): \(resolution.summaryLine)")
                }
                print(formatter.info("Dry-run mode — no files were imported."))
                return
            }

            // MARK: Resolve recipe

            var newRecipe: Recipe? = nil
            var oldRecipe: ProcessingRecipe? = nil
            if recipe.lowercased() != "none" {
                do {
                    let resolvedRecipe = try Self.resolveImportRecipe(named: recipe)
                    newRecipe = resolvedRecipe.newRecipe
                    oldRecipe = resolvedRecipe.legacyRecipe
                } catch let batchError as BatchImportError {
                    print(formatter.error(batchError.errorDescription ?? batchError.localizedDescription))
                    throw CLIExitCode.inputError.exitCode
                }
            }

            // MARK: Resolve quality binning

            let binningScheme: QualityBinningScheme
            switch qualityBinning.lowercased() {
            case "illumina4":
                binningScheme = .illumina4
            case "eightlevel", "eight_level", "eight-level":
                binningScheme = .eightLevel
            case "none":
                binningScheme = .none
            default:
                print(formatter.error("Unknown quality-binning value '\(qualityBinning)'. Valid: illumina4, eightLevel, none"))
                throw CLIExitCode.inputError.exitCode
            }

            // MARK: Resolve compression level

            guard let compLevel = CompressionLevel(rawValue: compression.lowercased()) else {
                print(formatter.error(
                    "Unknown compression '\(compression)'. Valid: fast, balanced, maximum"
                ))
                throw CLIExitCode.inputError.exitCode
            }

            // MARK: Resolve clumping tool

            let requestedClumpingTool: ClumpingTool?
            do {
                requestedClumpingTool = noOptimizeStorage
                    ? ClumpingTool.none
                    : try clumpingTool.map(Self.parseClumpingTool)
            } catch {
                print(formatter.error("Unknown clumping-tool value '\(clumpingTool ?? "")'. Valid: auto, bbtools, trim-galore, none"))
                throw CLIExitCode.inputError.exitCode
            }

            // MARK: Build config

            let projectURL = URL(fileURLWithPath: project)
            let logDirURL = logDir.map { URL(fileURLWithPath: $0) }
            let threadCount = globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount

            let config = FASTQBatchImporter.ImportConfig(
                projectDirectory: projectURL,
                platform: platformRequest,
                recipe: oldRecipe,
                newRecipe: newRecipe,
                qualityBinning: binningScheme,
                optimizeStorage: Self.requestedOptimizeStorage(
                    noOptimizeStorage: noOptimizeStorage,
                    clumpingTool: requestedClumpingTool
                ),
                clumpingTool: requestedClumpingTool,
                compressionLevel: compLevel,
                threads: threadCount,
                logDirectory: logDirURL,
                forceReimport: force,
                pairing: pairingChoice
            )

            if !dryRun {
                try await Self.installRequiredManagedDatabases(
                    requiredIDs: Self.requiredManagedDatabaseIDs(
                        legacyRecipe: oldRecipe,
                        newRecipe: newRecipe
                    ),
                    formatter: formatter,
                    isQuiet: globalOptions.quiet
                )
            }

            // MARK: Run import

            if !globalOptions.quiet {
                print(formatter.info("Starting import with \(threadCount) thread(s)…"))
                print("")
            }

            let result = await FASTQBatchImporter.runBatchImport(
                pairs: effectivePairs,
                config: config,
                log: { event in
                    if !isJSON, !globalOptions.quiet, case .platformResolved(let sample, let platform, let source, _, _, _, let message) = event {
                        let line = "\(sample): \(message)"
                        print(platform == "unknown" && source == "inferred" ? formatter.warning(line) : formatter.info(line))
                    }
                    if !isJSON, case .notice(let sample, let message) = event, message.hasPrefix("--platform ") {
                        print(formatter.warning("\(sample): \(message)"))
                    }
                    if isJSON || !globalOptions.quiet {
                        let json = FASTQBatchImporter.encodeLogEvent(event)
                        print(json)
                    }
                }
            )

            // MARK: Print summary

            print("")
            print(formatter.header("Import Summary"))
            print("")
            print(formatter.keyValueTable([
                ("Completed", "\(result.completed)"),
                ("Skipped",   "\(result.skipped)"),
                ("Failed",    "\(result.failed)"),
                ("Duration",  String(format: "%.1fs", result.totalDurationSeconds)),
            ]))

            if !result.errors.isEmpty {
                print("")
                print(formatter.warning("Failed samples:"))
                for (sample, error) in result.errors {
                    print(formatter.error("  \(sample): \(error)"))
                }
                throw CLIExitCode.workflowError.exitCode
            }
        }

        static func requiredManagedDatabaseIDs(
            legacyRecipe: ProcessingRecipe?,
            newRecipe: Recipe?
        ) -> [String] {
            var ids = Set<String>()

            for step in legacyRecipe?.steps ?? [] where step.kind == .humanReadScrub {
                let databaseID = step.humanScrubDatabaseID ?? DeaconPanhumanDatabaseInstaller.databaseID
                ids.insert(Self.canonicalHumanReadRemovalDatabaseID(for: databaseID))
            }

            for step in newRecipe?.steps ?? [] {
                if Self.newRecipeStepRequiresHumanScrubber(step) {
                    let configuredID = step.params?["database"]?.stringValue ?? DeaconPanhumanDatabaseInstaller.databaseID
                    ids.insert(Self.canonicalHumanReadRemovalDatabaseID(for: configuredID))
                } else if Self.newRecipeStepRequiresRibokmers(step) {
                    let configuredID = step.params?["database"]?.stringValue ?? DeaconRibokmersDatabaseInstaller.databaseID
                    ids.insert(DatabaseRegistry.canonicalDatabaseID(for: configuredID))
                }
            }

            return ids.sorted()
        }

        static func resolveImportRecipe(
            named name: String,
            recipes: [Recipe] = RecipeRegistryV2.allRecipes()
        ) throws -> (newRecipe: Recipe?, legacyRecipe: ProcessingRecipe?) {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized != "none" else {
                return (nil, nil)
            }

            let recipeID = v2RecipeAliases[normalized] ?? normalized
            if let recipe = recipes.first(where: { $0.id.lowercased() == recipeID }) {
                return (recipe, nil)
            }

            return (nil, try FASTQBatchImporter.resolveRecipe(named: name))
        }

        /// What the storage flags ask for, or nil when they ask nothing.
        /// `--no-optimize-storage` and `--clumping-tool` are requests, and the
        /// import sheet passes `--clumping-tool` when its box is ticked. With
        /// neither, the platform decides. Short reads are reordered, and
        /// Unknown and long reads are not.
        static func requestedOptimizeStorage(noOptimizeStorage: Bool, clumpingTool: ClumpingTool?) -> Bool? {
            noOptimizeStorage ? false : clumpingTool.map(\.isClumpingEnabled)
        }

        static func parseClumpingTool(_ value: String) throws -> ClumpingTool {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "auto":
                return .auto
            case "bbtools", "clumpify", "clumpify.sh":
                return .bbtools
            case "trim-galore", "trimgalore", "trim_galore":
                return .trimGalore
            case "none", "skip", "off", "false":
                return .none
            default:
                struct UnknownClumpingTool: Error {}
                throw UnknownClumpingTool()
            }
        }

        private static let v2RecipeAliases: [String: String] = [
            "vsp2": "vsp2-target-enrichment",
        ]

        /// The legacy `ProcessingRecipe` names ``resolveImportRecipe(named:recipes:)``
        /// falls back to when no recipe file matches. Every name here resolves.
        static let legacyRecipeNames: [String] = ["wgs", "hifi"]

        /// Every `--recipe` value that resolves, in the order the help lists
        /// them: the recipe files' own IDs, then the short aliases, then the
        /// legacy names. The help used to list `vsp2, wgs, hifi` while the
        /// IDs that actually resolve read like `vsp2-target-enrichment`.
        static func availableRecipeNames(recipes: [Recipe] = RecipeRegistryV2.allRecipes()) -> [String] {
            var names: [String] = []
            for recipe in recipes where !names.contains(recipe.id) {
                names.append(recipe.id)
            }
            for alias in v2RecipeAliases.keys.sorted() where !names.contains(alias) {
                names.append(alias)
            }
            for legacy in legacyRecipeNames where !names.contains(legacy) {
                names.append(legacy)
            }
            return names
        }

        static func recipeHelpNames(recipes: [Recipe] = RecipeRegistryV2.allRecipes()) -> String {
            availableRecipeNames(recipes: recipes).joined(separator: ", ")
        }

        static func recipeHelpDiscussion(recipes: [Recipe] = RecipeRegistryV2.allRecipes()) -> String {
            var lines: [String] = []
            for recipe in recipes {
                lines.append("\(recipe.id): \(recipe.name)")
            }
            for (alias, target) in v2RecipeAliases.sorted(by: { $0.key < $1.key }) {
                lines.append("\(alias): alias of \(target)")
            }
            lines.append("wgs: the built-in Illumina whole-genome recipe")
            lines.append("hifi: the built-in PacBio HiFi recipe")
            return lines.joined(separator: "\n")
        }

        static func canonicalHumanReadRemovalDatabaseID(for requestedID: String) -> String {
            let canonical = DatabaseRegistry.canonicalDatabaseID(for: requestedID)
            if canonical == HumanScrubberDatabaseInstaller.databaseID {
                return DeaconPanhumanDatabaseInstaller.databaseID
            }
            return canonical
        }

        static func installRequiredManagedDatabases(
            requiredIDs: [String],
            formatter: TerminalFormatter,
            isQuiet: Bool,
            databaseRegistry: any ManagedDatabaseProvisioning = DatabaseRegistry.shared,
            emit: @escaping @Sendable (String) -> Void = { print($0) }
        ) async throws {
            guard !requiredIDs.isEmpty else { return }

            for databaseID in requiredIDs {
                let manifest = await databaseRegistry.requiredDatabaseManifest(for: databaseID)
                let displayName = manifest?.displayName ?? databaseID
                if await databaseRegistry.isDatabaseInstalled(databaseID) {
                    if !isQuiet {
                        emit(formatter.info("Using installed \(displayName)."))
                    }
                    continue
                }

                if !isQuiet {
                    emit(formatter.info("Installing required database: \(displayName)…"))
                }

                do {
                    _ = try await databaseRegistry.installManagedDatabase(
                        databaseID,
                        reinstall: false
                    ) { progress, message in
                        guard !isQuiet else { return }
                        let percent = Int(progress * 100)
                        emit(formatter.info("[\(percent)%] \(message)"))
                    }
                } catch let error as HumanScrubberDatabaseError {
                    emit(formatter.error(error.localizedDescription))
                    throw CLIExitCode.dependency.exitCode
                } catch {
                    emit(formatter.error("Failed to install \(displayName): \(error.localizedDescription)"))
                    throw CLIExitCode.dependency.exitCode
                }
            }
        }

        private static func newRecipeStepRequiresHumanScrubber(_ step: RecipeStep) -> Bool {
            let type = step.type.lowercased()
            return type == "human-read-scrub"
                || type == "human-scrub"
                || type == "sra-human-scrubber"
                || type == "deacon-scrub"
        }

        private static func newRecipeStepRequiresRibokmers(_ step: RecipeStep) -> Bool {
            let type = step.type.lowercased()
            return type == "deacon-ribo-filter"
                || type == "deacon-ribo"
                || type == "ribokmers"
        }
    }
}
