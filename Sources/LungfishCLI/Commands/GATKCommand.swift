// GATKCommand.swift - Dry-run GATK command construction wrappers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

struct GATKCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gatk",
        abstract: "Construct GATK4 commands for germline variant workflows",
        discussion: """
        Builds reproducible GATK command lines without executing GATK. This first slice is
        intended for dry-run validation and workflow integration tests; execution, bundle
        attachment, and GUI dialogs are follow-up milestones.
        """,
        subcommands: [
            HaplotypeCallerSubcommand.self,
            JointGenotypeSubcommand.self,
            FilterSubcommand.self,
            SelectSubcommand.self,
            VariantsToTableSubcommand.self,
        ]
    )

    static func emit(commands: [LungfishWorkflow.GATKCommand], emit: (String) -> Void) {
        for command in commands {
            emit(command.shellCommand)
        }
    }
}

extension GATKCLICommand {
    struct HaplotypeCallerSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "haplotype-caller",
            abstract: "Construct a GATK HaplotypeCaller command"
        )

        @Option(name: .customLong("reference"), help: "Reference FASTA path")
        var reference: String

        @Option(name: .customLong("bam"), help: "Input BAM path")
        var bam: String

        @Option(name: .customLong("output"), help: "Output VCF or GVCF path")
        var output: String

        @Option(name: .customLong("emit-ref-confidence"), help: "Emit reference confidence: GVCF or NONE")
        var emitReferenceConfidence: String = GATKEmitReferenceConfidence.gvcf.rawValue

        @Option(name: .customLong("ploidy"), help: "Sample ploidy")
        var ploidy: Int = 2

        @Option(name: .customLong("intervals"), help: "Optional intervals BED/list/contig path")
        var intervals: String?

        @Option(name: .customLong("pcr-indel-model"), help: "GATK PCR indel model")
        var pcrIndelModel: String = "CONSERVATIVE"

        @Option(name: .customLong("stand-call-conf"), help: "Calling confidence threshold for non-GVCF mode")
        var standCallConf: Double = 30.0

        @Option(name: .customLong("max-alternate-alleles"), help: "Maximum alternate alleles")
        var maxAlternateAlleles: Int = 6

        @Option(name: .customLong("pair-hmm-threads"), help: "Native PairHMM threads")
        var pairHMMThreads: Int = 4

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse gatk haplotype-caller arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            let erc = GATKEmitReferenceConfidence(rawValue: emitReferenceConfidence.uppercased()) ?? .gvcf
            let config = GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: URL(fileURLWithPath: reference),
                inputBAMURL: URL(fileURLWithPath: bam),
                outputVCFURL: URL(fileURLWithPath: output),
                emitReferenceConfidence: erc,
                ploidy: ploidy,
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) },
                pcrIndelModel: pcrIndelModel,
                standardMinConfidenceThresholdForCalling: standCallConf,
                maxAlternateAlleles: maxAlternateAlleles,
                nativePairHMMThreads: pairHMMThreads,
                extraArguments: try parseExtraArgs()
            )
            GATKCLICommand.emit(commands: [GATKCommandBuilder.haplotypeCallerCommand(config)], emit: emit)
        }

        private func parseExtraArgs() throws -> [String] {
            do {
                return try AdvancedCommandLineOptions.parse(extraArgs)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }
    }

    struct JointGenotypeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "joint-genotype",
            abstract: "Construct GATK joint genotyping commands"
        )

        @Option(name: .customLong("reference"), help: "Reference FASTA path")
        var reference: String

        @Option(name: .customLong("gvcf"), help: "Input sample GVCF path. Repeat for each sample.")
        var gvcfs: [String] = []

        @Option(name: .customLong("output"), help: "Output cohort VCF path")
        var output: String

        @Option(name: .customLong("intermediate"), help: "Combined GVCF path or GenomicsDB workspace path")
        var intermediate: String

        @Option(name: .customLong("combine-strategy"), help: "auto, combine-gvcfs, or genomicsdb")
        var combineStrategy: String = GATKJointGenotypingStrategy.auto.rawValue

        @Option(name: .customLong("intervals"), help: "Optional intervals BED/list/contig path")
        var intervals: String?

        func run() async throws {
            let strategy = GATKJointGenotypingStrategy(rawValue: combineStrategy) ?? .auto
            let config = GATKJointGenotypingConfiguration(
                referenceFASTAURL: URL(fileURLWithPath: reference),
                inputGVCFURLs: gvcfs.map { URL(fileURLWithPath: $0) },
                outputVCFURL: URL(fileURLWithPath: output),
                intermediateURL: URL(fileURLWithPath: intermediate),
                strategy: strategy,
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) }
            )
            GATKCLICommand.emit(commands: GATKCommandBuilder.jointGenotypingCommands(config)) { print($0) }
        }
    }

    struct FilterSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "filter",
            abstract: "Construct a GATK VariantFiltration command"
        )

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("preset"), help: "best-practices-snp, best-practices-indel, best-practices-both")
        var preset: String = GATKVariantFiltrationPreset.bestPracticesBoth.rawValue

        @Option(name: .customLong("output"), help: "Output filtered VCF path")
        var output: String

        func run() async throws {
            let resolvedPreset = GATKVariantFiltrationPreset(rawValue: preset) ?? .bestPracticesBoth
            let config = GATKVariantFiltrationConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputVCFURL: URL(fileURLWithPath: output),
                preset: resolvedPreset
            )
            GATKCLICommand.emit(commands: [GATKCommandBuilder.variantFiltrationCommand(config)]) { print($0) }
        }
    }

    struct SelectSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select",
            abstract: "Construct a GATK SelectVariants command"
        )

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("sample"), help: "Optional sample ID")
        var sample: String?

        @Option(name: .customLong("type"), help: "Optional variant type: SNP, INDEL, or MIXED")
        var type: String?

        @Option(name: .customLong("intervals"), help: "Optional intervals BED/list/contig path")
        var intervals: String?

        @Option(name: .customLong("output"), help: "Output selected VCF path")
        var output: String

        func run() async throws {
            let variantType = type.flatMap { GATKSelectedVariantType(rawValue: $0.uppercased()) }
            let config = GATKSelectVariantsConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputVCFURL: URL(fileURLWithPath: output),
                sampleID: sample,
                variantType: variantType,
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) }
            )
            GATKCLICommand.emit(commands: [GATKCommandBuilder.selectVariantsCommand(config)]) { print($0) }
        }
    }

    struct VariantsToTableSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "variants-to-table",
            abstract: "Construct a GATK VariantsToTable command"
        )

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("fields"), help: "Comma-separated VCF fields")
        var fields: String = "CHROM,POS,REF,ALT,QUAL,AF,DP"

        @Option(name: .customLong("output"), help: "Output TSV path")
        var output: String

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse gatk variants-to-table arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            let config = GATKVariantsToTableConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputTableURL: URL(fileURLWithPath: output),
                fields: fields.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            )
            GATKCLICommand.emit(commands: [GATKCommandBuilder.variantsToTableCommand(config)], emit: emit)
        }
    }
}
