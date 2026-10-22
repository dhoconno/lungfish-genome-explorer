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
    /// and with `--format json` prints version 2 events on stdout (`ImportFastqReporter`).
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

        /// The settings `fetch sra download --bundle` takes too (lane A45 M3). The properties below
        /// forward their old names.
        @OptionGroup var importOptions: ImportFastqOptions

        var recipe: String { importOptions.recipe }
        var qualityBinning: String { importOptions.qualityBinning }
        var platform: String { importOptions.platform }
        var pairing: String { importOptions.pairing }
        var noOptimizeStorage: Bool { importOptions.noOptimizeStorage }
        var clumpingTool: String? { importOptions.clumpingTool }
        var compression: String { importOptions.compression }

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

        @Flag(
            name: .customLong("force"),
            help: ArgumentHelp(
                "Reimport samples even if bundle already exists",
                discussion: "A bundle that an earlier sample of the same import wrote is never replaced, and no "
                    + "sample writes a bundle that an earlier sample of the same import failed to write."
            )
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

        @Option(
            name: .customLong("clumpify-heap-gb"),
            help: "Java heap for BBTools clumpify in GB, from 1 up to this host's physical memory (default: sized from this host's free memory)"
        )
        var clumpifyHeapGB: Int?

        @OptionGroup var globalOptions: GlobalOptions

        /// Thread count sourced from the shared `--threads` / `-t` global option.
        var threads: Int? { globalOptions.threads }

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            // With --format json the run prints version 2 events and its human text on standard error
            // (ImportFastqReporter). Every failure below ends in one failed line.
            let reporter = ImportFastqReporter(
                globalOptions: globalOptions, formatter: formatter, projectDirectory: URL(fileURLWithPath: project)
            )
            reporter.start()

            // The detection, the unpaired-reads check and the import are shared with
            // `fetch sra download --bundle` (FASTQImportRun).
            let importRun = FASTQImportRun(
                input: input, samplesheet: samplesheet, project: project, recipe: recipe,
                qualityBinning: qualityBinning, logDir: logDir, dryRun: dryRun, platform: platform,
                pairing: pairing, noOptimizeStorage: noOptimizeStorage, clumpingTool: clumpingTool,
                compression: compression, force: force, name: name, recursive: recursive, threads: threads,
                clumpifyHeapGB: clumpifyHeapGB,
                quiet: globalOptions.quiet, useColors: globalOptions.useColors
            )
            guard let result = try await importRun.run(reporter: reporter, cancellation: .installsSIGTERMHandler) else {
                reporter.complete(message: "Dry-run mode — no files were imported.")
                return
            }

            // MARK: Print summary

            reporter.text("")
            reporter.text(formatter.header("Import Summary"))
            reporter.text("")
            reporter.text(formatter.keyValueTable([
                ("Completed", "\(result.completed)"),
                ("Skipped",   "\(result.skipped)"),
                ("Failed",    "\(result.failed)"),
                ("Duration",  String(format: "%.1fs", result.totalDurationSeconds)),
            ]))

            if !result.errors.isEmpty {
                reporter.text("")
                reporter.text(formatter.warning("Failed samples:"))
                for (sample, error) in result.errors {
                    reporter.text(formatter.error("  \(sample): \(error)"))
                }
                throw reporter.failSamples(result.errors)
            }
            reporter.complete(message: "Imported \(result.completed) sample(s)")
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

        /// Resolves a `--recipe` value to the recipe file or the legacy recipe it names.
        ///
        /// Only the names in ``legacyRecipeNames`` resolve to a legacy `ProcessingRecipe`.
        /// A name that stands for a recipe file, such as the `vsp2` alias, never falls back to
        /// a legacy recipe of the same short name, because that ran a different chain than the
        /// one asked for and said nothing. When no recipe file matches, the import stops with
        /// ``RecipeFileUnavailable``, which says what to do.
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
            if legacyRecipeNames.contains(normalized) {
                return (nil, try FASTQBatchImporter.resolveRecipe(named: normalized))
            }
            // An alias stands for a recipe file, and with no recipe file loaded no name can be
            // told from a recipe file's ID, so both stop here instead of guessing.
            if v2RecipeAliases[normalized] != nil || recipes.isEmpty {
                throw RecipeFileUnavailable(
                    requested: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    recipeID: recipeID,
                    loaded: recipes.map(\.id)
                )
            }
            // Not a recipe file and not a legacy name. The legacy resolver words the refusal
            // for "amplicon" and for unknown names, and nothing it accepts is used here.
            _ = try FASTQBatchImporter.resolveRecipe(named: name)
            throw BatchImportError.unknownRecipe(name)
        }

        /// A recipe file the import asked for did not load. The import stops here, because
        /// running another recipe in its place would change the science silently.
        struct RecipeFileUnavailable: Error, LocalizedError {
            let requested: String
            let recipeID: String
            let loaded: [String]

            var errorDescription: String? {
                let subject = requested.lowercased() == recipeID
                    ? "Recipe '\(recipeID)'"
                    : "Recipe '\(recipeID)' (asked for as '\(requested)')"
                let lead = "\(subject) is not available, and no other recipe was run in its place."
                guard !loaded.isEmpty else {
                    return "\(lead) \(FastqSubcommand.noRecipeFilesNotice) \(FastqSubcommand.noRecipeFilesAdvice) Nothing was imported."
                }
                let found = loaded.joined(separator: ", ")
                return "\(lead) The recipe files this lungfish-cli loaded are \(found). The file for \(recipeID) may be missing or damaged. Reinstall Lungfish or use one of those names. Nothing was imported."
            }
        }

        /// Why no recipe file loads, shared by the refusal and the help. The recipe files ship
        /// inside the Lungfish app, and a standalone lungfish-cli trusts no other location.
        static let noRecipeFilesNotice = "This lungfish-cli found no recipe files. They ship inside the Lungfish app, so a lungfish-cli that runs outside the app, such as one built with 'swift build -c release', cannot load them."
        static let noRecipeFilesAdvice = "Run the lungfish-cli inside the app, at Contents/MacOS/lungfish-cli in the app's folder, or run a debug build."

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
            // An alias is listed only while the recipe file it stands for is loaded.
            for (alias, target) in v2RecipeAliases.sorted(by: { $0.key < $1.key })
            where !names.contains(alias) && recipes.contains(where: { $0.id.lowercased() == target }) {
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
            for (alias, target) in v2RecipeAliases.sorted(by: { $0.key < $1.key })
            where recipes.contains(where: { $0.id.lowercased() == target }) {
                lines.append("\(alias): alias of \(target)")
            }
            lines.append("wgs: the built-in Illumina whole-genome recipe")
            lines.append("hifi: the built-in PacBio HiFi recipe")
            if recipes.isEmpty {
                let usable = legacyRecipeNames.joined(separator: " and ")
                lines.append("\(noRecipeFilesNotice) Only \(usable) run from this lungfish-cli. \(noRecipeFilesAdvice)")
            }
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
            emit: @escaping @Sendable (String) -> Void = { print($0) },
            failure: @escaping @Sendable (String) -> Void = { _ in }
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
                    failure(error.localizedDescription)
                    throw CLIExitCode.dependency.exitCode
                } catch {
                    let message = "Failed to install \(displayName): \(error.localizedDescription)"
                    emit(formatter.error(message))
                    failure(message)
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
