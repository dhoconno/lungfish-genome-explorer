// EsVirituCommand.swift - CLI command for EsViritu viral metagenomics
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// Run EsViritu viral detection on FASTQ files.
///
/// This command configures and executes the EsViritu pipeline for viral
/// metagenomics analysis. It supports both single-end and paired-end input,
/// and includes a subcommand for database management.
///
/// ## Examples
///
/// ```
/// # Single-end viral detection
/// lungfish esviritu detect --input sample.fastq.gz --sample MySample --db /path/to/db
///
/// # Paired-end detection with custom threads
/// lungfish esviritu detect --input R1.fastq.gz R2.fastq.gz --paired --sample MySample --db /path/to/db --threads 8
///
/// # Download the EsViritu database
/// lungfish esviritu download-db
///
/// # Check database status
/// lungfish esviritu db-status
/// ```
struct EsVirituCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "esviritu",
        abstract: "Run EsViritu viral metagenomics detection on FASTQ files",
        discussion: """
        Detect and characterize viruses from metagenomic sequencing data
        using EsViritu. Requires the EsViritu conda package and its curated
        viral reference database.

        Install the tool: lungfish conda install esviritu
        Download the database: lungfish esviritu download-db
        """,
        subcommands: [
            DetectSubcommand.self,
            DownloadDBSubcommand.self,
            DBStatusSubcommand.self,
        ],
        defaultSubcommand: DetectSubcommand.self
    )
}

// MARK: - Detect

extension EsVirituCommand {

    /// Run EsViritu viral detection on FASTQ input files.
    struct DetectSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detect",
            abstract: "Run EsViritu viral detection on FASTQ files"
        )

        // MARK: - Arguments

        @Option(
            name: [.customLong("input"), .customShort("i")],
            parsing: .upToNextOption,
            help: "Input FASTQ file(s). Provide two files for paired-end."
        )
        var inputFiles: [String]

        @Option(
            name: [.customLong("sample"), .customShort("s")],
            help: "Sample name for output file prefixes"
        )
        var sampleName: String

        @Option(
            name: .customLong("db"),
            help: "Path to EsViritu database directory (default: auto-detect)"
        )
        var databasePath: String?

        @Option(
            name: [.customLong("output"), .customShort("o")],
            help: "Output directory (default: current directory)"
        )
        var outputDir: String?

        @Flag(
            name: .customLong("paired"),
            help: "Input files are paired-end reads"
        )
        var pairedEnd: Bool = false

        @Flag(
            name: .customLong("no-qc"),
            help: "Skip quality filtering (fastp)"
        )
        var noQC: Bool = false

        @Option(
            name: .customLong("min-read-length"),
            help: "Minimum read length after filtering (default: 100)"
        )
        var minReadLength: Int = 100

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional EsViritu arguments passed verbatim"
        )
        var extraArgs: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        // MARK: - Execution

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse esviritu detect arguments.")
            }
            return parsed
        }

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            // Resolve input files.
            let inputURLs = inputFiles.map { URL(fileURLWithPath: $0) }
            for url in inputURLs {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    print(formatter.error("Input file not found: \(url.path)"))
                    throw CLIExitCode.inputError.exitCode
                }
            }

            // Validate paired-end input count.
            if pairedEnd && inputURLs.count != 2 {
                print(formatter.error("Paired-end mode requires exactly 2 input files, got \(inputURLs.count)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Resolve database path.
            let dbURL: URL
            if let dbPath = databasePath {
                dbURL = URL(fileURLWithPath: dbPath)
            } else {
                // Try auto-detect from the database manager.
                let dbManager = EsVirituDatabaseManager.shared
                let isInstalled = await dbManager.isInstalled()
                if isInstalled {
                    dbURL = await dbManager.databaseURL
                } else {
                    print(formatter.error("EsViritu database not found. Download it first:"))
                    print(formatter.info("  lungfish esviritu download-db"))
                    throw CLIExitCode.dependency.exitCode
                }
            }

            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                print(formatter.error("Database directory not found: \(dbURL.path)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Resolve output directory.
            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("esviritu-\(sampleName)")
            }

            let effectiveThreads = globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount

            // Build config.
            let config = EsVirituConfig(
                inputFiles: inputURLs,
                isPairedEnd: pairedEnd,
                sampleName: sampleName,
                outputDirectory: outputDirectory,
                databasePath: dbURL,
                qualityFilter: !noQC,
                minReadLength: minReadLength,
                threads: effectiveThreads,
                extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
            )

            // Print configuration.
            print(formatter.header("EsViritu Viral Detection"))
            print("")
            print(formatter.keyValueTable([
                ("Input files", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
                ("Paired-end", pairedEnd ? "yes" : "no"),
                ("Sample name", sampleName),
                ("Database", dbURL.path),
                ("Quality filter", config.qualityFilter ? "yes" : "no"),
                ("Min read length", String(config.minReadLength)),
                ("Threads", String(config.threads)),
                ("Output", outputDirectory.path),
            ]))
            print("")

            // Run pipeline.
            let pipeline = EsVirituPipeline.shared

            let result = try await pipeline.detect(config: config) { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }

            // Clear progress line.
            print("")
            print("")

            // Print summary.
            print(formatter.header("Results"))
            print("")
            print(result.summary)
            print("")

            // Print output file paths.
            print(formatter.header("Output Files"))
            print("  Detection: \(formatter.path(result.detectionURL.path))")
            if let assembly = result.assemblyURL {
                print("  Assembly:  \(formatter.path(assembly.path))")
            }
            if let taxProfile = result.taxProfileURL {
                print("  Profile:   \(formatter.path(taxProfile.path))")
            }
            if let coverage = result.coverageURL {
                print("  Coverage:  \(formatter.path(coverage.path))")
            }
            print("")
            print(formatter.success("Detection completed in \(String(format: "%.1f", result.runtime))s"))
            print("\(result.virusCount) virus(es) detected")
        }

        func makeConfigForTesting(
            databaseURL: URL,
            outputDirectory: URL
        ) throws -> EsVirituConfig {
            EsVirituConfig(
                inputFiles: inputFiles.map { URL(fileURLWithPath: $0) },
                isPairedEnd: pairedEnd,
                sampleName: sampleName,
                outputDirectory: outputDirectory,
                databasePath: databaseURL,
                qualityFilter: !noQC,
                minReadLength: minReadLength,
                threads: globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount,
                extraArguments: try AdvancedCommandLineOptions.parse(extraArgs)
            )
        }
    }
}

// MARK: - Download Database

extension EsVirituCommand {

    /// Download the EsViritu viral reference database from Zenodo.
    struct DownloadDBSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download-db",
            abstract: "Download the EsViritu viral reference database"
        )

        @Flag(
            name: .customLong("force"),
            help: "Re-download even if the database is already installed"
        )
        var force: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let dbManager = EsVirituDatabaseManager.shared

            // Check if already installed.
            let isInstalled = await dbManager.isInstalled()
            if isInstalled && !force {
                let dbURL = await dbManager.databaseURL
                print(formatter.success(
                    "EsViritu database \(EsVirituDatabaseManager.currentVersion) is already installed at:"
                ))
                print("  \(formatter.path(dbURL.path))")
                print("")
                print("Use --force to re-download.")
                return
            }

            print(formatter.header("Downloading EsViritu Database"))
            print("  Version: \(EsVirituDatabaseManager.currentVersion)")
            print("  DOI: \(EsVirituDatabaseManager.zenodoDOI)")
            print("  Size: ~2 GB (compressed)")
            print("")

            let dbPath = try await dbManager.download { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }

            print("")
            print("")
            print(formatter.success("Database installed at: \(dbPath.path)"))
        }
    }
}

// MARK: - Database Status

extension EsVirituCommand {

    /// Check the status of the installed EsViritu database.
    struct DBStatusSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "db-status",
            abstract: "Check EsViritu database installation status"
        )

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let dbManager = EsVirituDatabaseManager.shared

            print(formatter.header("EsViritu Database Status"))
            print("")

            let isInstalled = await dbManager.isInstalled()
            if isInstalled {
                if let info = await dbManager.installedDatabaseInfo() {
                    let sizeStr = ByteCountFormatter.string(
                        fromByteCount: info.sizeBytes,
                        countStyle: .file
                    )
                    print(formatter.keyValueTable([
                        ("Status", "Installed"),
                        ("Version", info.version),
                        ("Path", info.path.path),
                        ("Size", sizeStr),
                    ]))
                } else {
                    print("  Status: Installed")
                }
            } else {
                print("  Status: Not installed")
                print("")
                print(formatter.info("Download with: lungfish esviritu download-db"))
            }
        }
    }
}
