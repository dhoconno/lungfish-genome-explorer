// TaxTriageCommand.swift - CLI command for TaxTriage metagenomic classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO

/// Run the TaxTriage metagenomic classification pipeline via Nextflow.
///
/// TaxTriage (JHU APL) is a Nextflow DSL2 pipeline for end-to-end metagenomic
/// classification with TASS confidence scoring. It requires Nextflow and a
/// container runtime (Docker or Apple Containerization).
///
/// ## Examples
///
/// ```
/// # Single sample with auto-detected platform
/// lungfish taxtriage --input sample.fastq.gz --sample MySample --output /results
///
/// # Paired-end with explicit database
/// lungfish taxtriage --input R1.fq.gz --input2 R2.fq.gz --sample S1 \
///     --db /path/to/k2db --output /results
///
/// # Multi-sample via samplesheet
/// lungfish taxtriage --samplesheet samples.csv --output /results
///
/// # Check prerequisites
/// lungfish taxtriage check-prerequisites
/// ```
struct TaxTriageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "taxtriage",
        abstract: "Run TaxTriage metagenomic classification pipeline",
        discussion: """
            Execute the TaxTriage Nextflow pipeline (jhuapl-bio/taxtriage) for
            metagenomic classification with confidence scoring. Requires Nextflow
            and Docker (or Apple Containerization on macOS 26+).

            TaxTriage supports Illumina, Oxford Nanopore, and PacBio platforms.
            Results include organism identification reports, TASS confidence metrics,
            and optional Krona interactive visualizations.
            """,
        subcommands: [
            RunSubcommand.self,
            CheckPrerequisitesSubcommand.self,
        ],
        defaultSubcommand: RunSubcommand.self
    )
}

// MARK: - Run Subcommand

extension TaxTriageCommand {

    /// Execute the TaxTriage pipeline.
    struct RunSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Execute TaxTriage classification on FASTQ files"
        )

        // MARK: - Input Options

        @Option(
            name: .customLong("input"),
            help: "Input FASTQ file (R1 or single-end)"
        )
        var input: String?

        @Option(
            name: .customLong("input2"),
            help: "Second FASTQ file (R2 for paired-end)"
        )
        var input2: String?

        @Option(
            name: .customLong("sample"),
            help: "Sample identifier (required with --input)"
        )
        var sampleId: String?

        @Option(
            name: .customLong("samplesheet"),
            help: "Path to a TaxTriage samplesheet CSV (alternative to --input)"
        )
        var samplesheet: String?

        @Option(
            name: .customLong("platform"),
            help: "Sequencing platform: illumina, oxford, pacbio (default: illumina)"
        )
        var platform: PlatformArgument = .illumina

        // MARK: - Output Options

        @Option(
            name: [.customLong("output"), .customShort("o")],
            help: "Output directory for results"
        )
        var outputDir: String

        // MARK: - Database Options

        @Option(
            name: .customLong("db"),
            help: "Path to existing Kraken2 database"
        )
        var databasePath: String?

        // MARK: - Pipeline Parameters

        @Option(
            name: .customLong("confidence"),
            help: "Kraken2 confidence threshold (default: 0.2)"
        )
        var confidence: Double = 0.2

        @Option(
            name: .customLong("top-hits"),
            help: "Number of top hits to report (default: 10)"
        )
        var topHits: Int = 10

        @Option(
            name: .customLong("rank"),
            help: "Taxonomic rank: D,P,C,O,F,G,S (default: S)"
        )
        var rank: String = "S"

        @Flag(
            name: .customLong("skip-assembly"),
            help: "Skip genome assembly steps (default: true)"
        )
        var skipAssembly: Bool = false

        @Flag(
            name: .customLong("no-skip-assembly"),
            help: "Enable genome assembly steps"
        )
        var noSkipAssembly: Bool = false

        @Flag(
            name: .customLong("skip-krona"),
            help: "Skip Krona visualization generation"
        )
        var skipKrona: Bool = false

        @Option(
            name: .customLong("max-memory"),
            help: "Maximum memory (Nextflow format, default: 16.GB)"
        )
        var maxMemory: String = "16.GB"

        @Option(
            name: .customLong("max-cpus"),
            help: "Maximum CPUs (default: auto)"
        )
        var maxCpus: Int?

        // MARK: - Nextflow Options

        @Option(
            name: .customLong("nf-profile"),
            help: "Nextflow execution profile (default: docker)"
        )
        var nfProfile: String = "docker"

        @Option(
            name: .customLong("revision"),
            help: "TaxTriage pipeline revision/branch (default: main)"
        )
        var revision: String = "main"

        @OptionGroup var globalOptions: GlobalOptions

        // MARK: - Validation

        func validate() throws {
            // Must provide either --input or --samplesheet
            if input == nil && samplesheet == nil {
                throw ValidationError(
                    "Provide either --input (with --sample) or --samplesheet"
                )
            }
            if input != nil && samplesheet != nil {
                throw ValidationError(
                    "Cannot use both --input and --samplesheet"
                )
            }
            if input != nil && sampleId == nil {
                throw ValidationError(
                    "--sample is required when using --input"
                )
            }
            if skipAssembly && noSkipAssembly {
                throw ValidationError(
                    "Cannot use both --skip-assembly and --no-skip-assembly"
                )
            }
        }

        // MARK: - Execution

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            let outputDirectory = URL(fileURLWithPath: outputDir)

            // Build samples from either --input or --samplesheet
            let samples: [TaxTriageSample]

            if let samplesheetPath = samplesheet {
                // Parse samplesheet
                let sheetURL = URL(fileURLWithPath: samplesheetPath)
                guard FileManager.default.fileExists(atPath: sheetURL.path) else {
                    print(formatter.error("Samplesheet not found: \(samplesheetPath)"))
                    throw ExitCode.failure
                }

                let entries = try TaxTriageSamplesheet.parse(url: sheetURL)
                samples = entries.map { entry in
                    let entryPlatform = TaxTriageConfig.Platform(
                        rawValue: entry.platform
                    ) ?? platform.toPlatform()
                    return TaxTriageSample(
                        sampleId: entry.sampleId,
                        fastq1: URL(fileURLWithPath: entry.fastq1Path),
                        fastq2: entry.fastq2Path.map {
                            URL(fileURLWithPath: $0)
                        },
                        platform: entryPlatform
                    )
                }
            } else {
                // Build single sample from --input
                guard let inputPath = input, let sid = sampleId else {
                    print(formatter.error("--input and --sample are required"))
                    throw ExitCode.failure
                }

                let fastq1 = URL(fileURLWithPath: inputPath)
                guard FileManager.default.fileExists(atPath: fastq1.path) else {
                    print(formatter.error("Input file not found: \(inputPath)"))
                    throw ExitCode.failure
                }

                var fastq2: URL?
                if let input2Path = input2 {
                    let r2 = URL(fileURLWithPath: input2Path)
                    guard FileManager.default.fileExists(atPath: r2.path) else {
                        print(formatter.error(
                            "Input R2 file not found: \(input2Path)"
                        ))
                        throw ExitCode.failure
                    }
                    fastq2 = r2
                }

                samples = [TaxTriageSample(
                    sampleId: sid,
                    fastq1: fastq1,
                    fastq2: fastq2,
                    platform: platform.toPlatform()
                )]
            }

            // Resolve database path
            var dbURL: URL?
            if let dbPath = databasePath {
                dbURL = URL(fileURLWithPath: dbPath)
                guard FileManager.default.fileExists(atPath: dbURL!.path) else {
                    print(formatter.error("Database not found: \(dbPath)"))
                    throw ExitCode.failure
                }
            }

            // Determine effective skipAssembly (default true unless --no-skip-assembly)
            let effectiveSkipAssembly: Bool
            if noSkipAssembly {
                effectiveSkipAssembly = false
            } else if skipAssembly {
                effectiveSkipAssembly = true
            } else {
                effectiveSkipAssembly = true
            }

            // Build configuration
            let config = TaxTriageConfig(
                samples: samples,
                platform: platform.toPlatform(),
                outputDirectory: outputDirectory,
                kraken2DatabasePath: dbURL,
                classifiers: ["kraken2"],
                topHitsCount: topHits,
                k2Confidence: confidence,
                rank: rank,
                skipAssembly: effectiveSkipAssembly,
                skipKrona: skipKrona,
                maxMemory: maxMemory,
                maxCpus: maxCpus ?? ProcessInfo.processInfo.activeProcessorCount,
                profile: nfProfile,
                containerRuntime: nil,
                revision: revision
            )

            // Print configuration summary
            print(formatter.header("TaxTriage Pipeline"))
            print("")
            print(formatter.keyValueTable([
                ("Samples", String(samples.count)),
                ("Platform", platform.rawValue),
                ("Database", dbURL?.lastPathComponent ?? "default"),
                ("Confidence", String(format: "%.2f", confidence)),
                ("Top hits", String(topHits)),
                ("Rank", rank),
                ("Skip assembly", effectiveSkipAssembly ? "yes" : "no"),
                ("Skip Krona", skipKrona ? "yes" : "no"),
                ("Max memory", maxMemory),
                ("Max CPUs", String(config.maxCpus)),
                ("Profile", nfProfile),
                ("Revision", revision),
                ("Output", outputDirectory.path),
            ]))
            print("")

            // Run pipeline
            let pipeline = TaxTriagePipeline.shared

            let result = try await pipeline.run(config: config) { fraction, message in
                if !globalOptions.quiet {
                    let pct = Int(fraction * 100)
                    print("\r\(formatter.info("[\(pct)%] \(message)"))  ", terminator: "")
                    fflush(stdout)
                }
            }

            // Clear progress line
            print("")
            print("")

            // Print results
            print(formatter.header("Results"))
            print("")
            print(result.summary)
            print("")

            // Print output files
            print(formatter.header("Output Files"))
            if !result.reportFiles.isEmpty {
                for report in result.reportFiles {
                    print("  Report:  \(formatter.path(report.path))")
                }
            }
            if !result.metricsFiles.isEmpty {
                for metrics in result.metricsFiles {
                    print("  Metrics: \(formatter.path(metrics.path))")
                }
            }
            if !result.kronaFiles.isEmpty {
                for krona in result.kronaFiles {
                    print("  Krona:   \(formatter.path(krona.path))")
                }
            }
            if let log = result.logFile {
                print("  Log:     \(formatter.path(log.path))")
            }
            print("")

            let runtimeStr = String(format: "%.1f", result.runtime)
            print(formatter.success(
                "TaxTriage completed in \(runtimeStr)s"
            ))
        }
    }
}

// MARK: - Check Prerequisites Subcommand

extension TaxTriageCommand {

    /// Verify that Nextflow and a container runtime are available.
    struct CheckPrerequisitesSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check-prerequisites",
            abstract: "Verify Nextflow and container runtime availability"
        )

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            print(formatter.header("TaxTriage Prerequisites"))
            print("")

            let pipeline = TaxTriagePipeline.shared
            let status = await pipeline.checkPrerequisites()

            // Nextflow
            if status.nextflowInstalled {
                let version = status.nextflowVersion ?? "unknown"
                print(formatter.success("Nextflow: installed (v\(version))"))
            } else {
                print(formatter.error("Nextflow: NOT INSTALLED"))
                print(formatter.info(
                    "  Install: curl -s https://get.nextflow.io | bash"
                ))
            }

            // Container runtime
            if status.containerRuntimeAvailable {
                let name = status.containerRuntimeName ?? "available"
                print(formatter.success("Container runtime: \(name)"))
            } else {
                print(formatter.error("Container runtime: NOT AVAILABLE"))
                print(formatter.info(
                    "  Install Docker Desktop or use Apple Containerization (macOS 26+)"
                ))
            }

            print("")

            if status.allSatisfied {
                print(formatter.success("All prerequisites met. Ready to run TaxTriage."))
            } else {
                print(formatter.error(
                    "Missing prerequisites. Install the tools listed above."
                ))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - PlatformArgument

/// ArgumentParser-compatible wrapper for ``TaxTriageConfig/Platform``.
enum PlatformArgument: String, ExpressibleByArgument, CaseIterable {
    case illumina
    case oxford
    case pacbio

    /// Converts to the workflow module's platform type.
    func toPlatform() -> TaxTriageConfig.Platform {
        switch self {
        case .illumina: return .illumina
        case .oxford: return .oxford
        case .pacbio: return .pacbio
        }
    }
}
