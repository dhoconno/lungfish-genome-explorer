// ImportFastqCommand.swift - CLI subcommand for batch FASTQ import
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// Disambiguate the two SequencingPlatform types that exist in LungfishIO and LungfishWorkflow.
private typealias WorkflowPlatform = LungfishWorkflow.SequencingPlatform

protocol ManagedDatabaseProvisioning: Sendable {
    func requiredDatabaseManifest(for id: String) async -> BundledDatabase?
    func isDatabaseInstalled(_ id: String) async -> Bool
    func installManagedDatabase(
        _ id: String,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL
}

extension DatabaseRegistry: ManagedDatabaseProvisioning {}

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
            abstract: "Batch-import FASTQ files into a Lungfish project"
        )

        @Argument(help: "Directory containing .fastq.gz files, or one or more FASTQ file paths")
        var input: [String]

        @Option(
            name: [.customLong("project"), .customShort("p")],
            help: "Path to .lungfish project directory"
        )
        var project: String

        @Option(
            name: .customLong("recipe"),
            help: "Processing recipe: vsp2, wgs, amplicon, hifi, none (default: none)"
        )
        var recipe: String = "none"

        @Option(
            name: .customLong("quality-binning"),
            help: "Quality binning: illumina4, eightLevel, none (default: illumina4)"
        )
        var qualityBinning: String = "illumina4"

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
            help: "Sequencing platform: illumina, ont, pacbio, ultima (default: auto-detect)"
        )
        var platform: String?

        @Flag(
            name: .customLong("no-optimize-storage"),
            help: "Skip read reordering for storage optimization"
        )
        var noOptimizeStorage: Bool = false

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

            guard !input.isEmpty else {
                print(formatter.error("At least one input path is required."))
                throw ExitCode.failure
            }

            // MARK: Detect pairs

            let pairs: [SamplePair]
            let fm = FileManager.default

            if input.count == 1 {
                // Single argument: could be a directory or a single file
                let inputURL = URL(fileURLWithPath: input[0])
                var isDirectory: ObjCBool = false
                let exists = fm.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)

                if exists && isDirectory.boolValue {
                    do {
                        if recursive {
                            pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(inputURL)
                        } else {
                            pairs = try FASTQBatchImporter.detectPairsFromDirectory(inputURL)
                        }
                    } catch let batchError as BatchImportError {
                        print(formatter.error(batchError.errorDescription ?? batchError.localizedDescription))
                        throw ExitCode.failure
                    }
                } else {
                    guard exists else {
                        print(formatter.error("Input not found: \(input[0])"))
                        throw ExitCode.failure
                    }
                    pairs = FASTQBatchImporter.detectPairs(from: [inputURL])
                }
            } else {
                // Multiple arguments: treat as explicit file paths
                var fileURLs: [URL] = []
                for path in input {
                    let url = URL(fileURLWithPath: path)
                    guard fm.fileExists(atPath: url.path) else {
                        print(formatter.error("Input file not found: \(path)"))
                        throw ExitCode.failure
                    }
                    fileURLs.append(url)
                }
                pairs = FASTQBatchImporter.detectPairs(from: fileURLs)
            }

            // MARK: Print detected pairs

            print(formatter.header("FASTQ Import"))
            print("")
            print(formatter.info("Detected \(pairs.count) sample(s):"))
            for (i, pair) in pairs.enumerated() {
                let index = String(format: "%3d", i + 1)
                if let r2 = pair.r2 {
                    print("  \(index). \(pair.sampleName)  [paired]")
                    print("        R1: \(pair.r1.lastPathComponent)")
                    print("        R2: \(r2.lastPathComponent)")
                } else {
                    print("  \(index). \(pair.sampleName)  [single-end]")
                    print("        R1: \(pair.r1.lastPathComponent)")
                }
            }
            print("")

            // MARK: Dry-run exit

            if dryRun {
                print(formatter.info("Dry-run mode — no files were imported."))
                return
            }

            // MARK: Resolve platform

            let resolvedPlatform: WorkflowPlatform
            if let platformStr = platform {
                guard let p = WorkflowPlatform(rawValue: platformStr.lowercased()) else {
                    print(formatter.error(
                        "Unknown platform '\(platformStr)'. Valid: illumina, ont, pacbio, ultima"
                    ))
                    throw ExitCode.failure
                }
                resolvedPlatform = p
            } else {
                // Auto-detect from first FASTQ header; fall back to .illumina
                resolvedPlatform = detectPlatformFromPairs(pairs) ?? .illumina
                if !globalOptions.quiet {
                    print(formatter.info("Platform: \(resolvedPlatform.displayName) (auto-detected)"))
                }
            }

            // MARK: Resolve recipe

            var newRecipe: Recipe? = nil
            var oldRecipe: ProcessingRecipe? = nil
            if recipe.lowercased() != "none" {
                // Search RecipeRegistryV2 by exact ID first, then by substring
                if let r = RecipeRegistryV2.allRecipes().first(where: {
                    $0.id == recipe || $0.id.contains(recipe.lowercased())
                }) {
                    newRecipe = r
                } else {
                    // Fall back to legacy recipe system (wgs, amplicon, hifi, etc.)
                    do {
                        oldRecipe = try FASTQBatchImporter.resolveRecipe(named: recipe)
                    } catch let batchError as BatchImportError {
                        print(formatter.error(batchError.errorDescription ?? batchError.localizedDescription))
                        throw ExitCode.failure
                    }
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
                throw ExitCode.failure
            }

            // MARK: Resolve compression level

            guard let compLevel = CompressionLevel(rawValue: compression.lowercased()) else {
                print(formatter.error(
                    "Unknown compression '\(compression)'. Valid: fast, balanced, maximum"
                ))
                throw ExitCode.failure
            }

            // MARK: Build config

            let projectURL = URL(fileURLWithPath: project)
            let logDirURL = logDir.map { URL(fileURLWithPath: $0) }
            let threadCount = globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount

            let config = FASTQBatchImporter.ImportConfig(
                projectDirectory: projectURL,
                platform: resolvedPlatform,
                recipe: oldRecipe,
                newRecipe: newRecipe,
                qualityBinning: binningScheme,
                optimizeStorage: !noOptimizeStorage,
                compressionLevel: compLevel,
                threads: threadCount,
                logDirectory: logDirURL,
                forceReimport: force
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

            let isJSON = globalOptions.outputFormat == .json
            let result = await FASTQBatchImporter.runBatchImport(
                pairs: pairs,
                config: config,
                log: { event in
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
                throw ExitCode.failure
            }
        }

        static func requiredManagedDatabaseIDs(
            legacyRecipe: ProcessingRecipe?,
            newRecipe: Recipe?
        ) -> [String] {
            var ids = Set<String>()

            for step in legacyRecipe?.steps ?? [] where step.kind == .humanReadScrub {
                let databaseID = step.humanScrubDatabaseID ?? HumanScrubberDatabaseInstaller.databaseID
                ids.insert(DatabaseRegistry.canonicalDatabaseID(for: databaseID))
            }

            for step in newRecipe?.steps ?? [] {
                guard Self.newRecipeStepRequiresHumanScrubber(step) else { continue }
                let configuredID = step.params?["database"]?.stringValue ?? DeaconPanhumanDatabaseInstaller.databaseID
                ids.insert(DatabaseRegistry.canonicalDatabaseID(for: configuredID))
            }

            return ids.sorted()
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
                    _ = try await databaseRegistry.installManagedDatabase(databaseID) { progress, message in
                        guard !isQuiet else { return }
                        let percent = Int(progress * 100)
                        emit(formatter.info("[\(percent)%] \(message)"))
                    }
                } catch let error as HumanScrubberDatabaseError {
                    emit(formatter.error(error.localizedDescription))
                    throw ExitCode.failure
                } catch {
                    emit(formatter.error("Failed to install \(displayName): \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
            }
        }

        // MARK: - Platform auto-detection

        /// Reads the first FASTQ header from the first pair's R1 file and attempts
        /// platform detection. Supports both plain and gzip-compressed files.
        private func detectPlatformFromPairs(_ pairs: [SamplePair]) -> WorkflowPlatform? {
            guard let first = pairs.first else { return nil }

            let r1 = first.r1
            let isGzipped = r1.pathExtension.lowercased() == "gz"

            let header: String
            if isGzipped {
                // Use gunzip -c and read only the first 1 KB to avoid blocking
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                process.arguments = ["-c", r1.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe() // suppress error output
                do {
                    try process.run()
                } catch {
                    return nil
                }
                let data = pipe.fileHandleForReading.readData(ofLength: 1024)
                process.terminate()
                header = String(data: data, encoding: .utf8)?
                    .components(separatedBy: "\n").first ?? ""
            } else {
                // Plain text — just open and read the first line
                guard let handle = FileHandle(forReadingAtPath: r1.path) else { return nil }
                let data = handle.readData(ofLength: 512)
                try? handle.close()
                header = String(data: data, encoding: .utf8)?
                    .components(separatedBy: "\n").first ?? ""
            }

            return WorkflowPlatform.detect(fromFASTQHeader: header)
        }
        private static func newRecipeStepRequiresHumanScrubber(_ step: RecipeStep) -> Bool {
            let type = step.type.lowercased()
            return type == "human-read-scrub"
                || type == "human-scrub"
                || type == "sra-human-scrubber"
                || type == "deacon-scrub"
        }
    }
}
