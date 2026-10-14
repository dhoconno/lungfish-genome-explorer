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
            and Docker Desktop (the pipeline runs with -profile docker).

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

// MARK: - Check Prerequisites Subcommand

extension TaxTriageCommand {

    /// Verify that Nextflow and a container runtime are available.
    struct CheckPrerequisitesSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check-prerequisites",
            abstract: "Verify Nextflow and container runtime availability"
        )

        @OptionGroup var globalOptions: GlobalOptions

        /// The probe `run()` hands the pipeline. The default runs `docker
        /// version`, the same probe the app's wizard row and `debug container`
        /// use. Only a test binds another, for one scope with
        /// `$containerRuntimeProbe.withValue`, so nothing can assign it.
        @TaskLocal static var containerRuntimeProbe: any ContainerRuntimeProbing = SystemContainerRuntimeProbe()

        /// The container-runtime lines of the report. The verdict is the
        /// Docker daemon's alone, matching the wizard row and `debug
        /// container`: Apple Containerization cannot run the pipeline, so it
        /// never turns this line green.
        static func containerRuntimeLines(status: PrerequisiteStatus, formatter: TerminalFormatter) -> [String] {
            if status.containerRuntimeAvailable {
                let name = status.containerRuntimeName ?? PipelineContainerRuntimeStatus.runtimeName
                return [formatter.success("Container runtime: \(name) (running)")]
            }
            let detail = status.containerRuntimeDetail
                ?? "\(PipelineContainerRuntimeStatus.runtimeName) is not available"
            return [
                formatter.error("Container runtime: not available (\(detail))"),
                formatter.info("  Install and start Docker Desktop, then run `lungfish-cli debug container`"),
            ]
        }

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            print(formatter.header("TaxTriage Prerequisites"))
            print("")

            let pipeline = TaxTriagePipeline(containerRuntimeProbe: Self.containerRuntimeProbe)
            let status = await pipeline.checkPrerequisites()

            // Nextflow
            if status.nextflowInstalled {
                let version = status.nextflowVersion ?? "unknown"
                print(formatter.success("Nextflow: installed (v\(version))"))
            } else {
                print(formatter.error("Nextflow: not installed"))
                // Nextflow is a managed Required Setup tool, not a
                // hand-installed one; point at the managed install.
                print(formatter.info(
                    "  Install: Nextflow is part of LGE's Required Setup. In the app, open the Welcome window and click Install, or run: lungfish-cli tools update --apply --yes --required-only"
                ))
            }

            for line in Self.containerRuntimeLines(status: status, formatter: formatter) {
                print(line)
            }

            print("")

            if status.allSatisfied {
                print(formatter.success("All prerequisites met. Ready to run TaxTriage."))
            } else {
                print(formatter.error(
                    "Missing prerequisites. Install the tools listed above."
                ))
                throw CLIExitCode.dependency.exitCode
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
