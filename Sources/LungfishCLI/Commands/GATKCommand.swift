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
        Builds reproducible GATK command lines by default. Pass --execute on a subcommand to
        run GATK through the managed gatk-core environment and write final-location provenance.
        """,
        subcommands: [
            HaplotypeCallerSubcommand.self,
            JointGenotypeSubcommand.self,
            FilterSubcommand.self,
            SelectSubcommand.self,
            VariantsToTableSubcommand.self,
            BQSRSubcommand.self,
            MarkDuplicatesSubcommand.self,
            ValidateSamSubcommand.self,
            LeftAlignSubcommand.self,
            CollectMetricsSubcommand.self,
        ]
    )

    static func emit(commands: [LungfishWorkflow.GATKCommand], emit: (String) -> Void) {
        for command in commands {
            emit(command.shellCommand)
        }
    }

    static func runOrPreview<Runner: GATKCommandRunning>(
        request: GATKPipelineExecutionRequest,
        execute: Bool,
        runner: Runner,
        emit: @escaping (String) -> Void
    ) async throws {
        guard execute else {
            GATKCLICommand.emit(commands: request.commands, emit: emit)
            return
        }

        let executor = GATKPipelineExecutor(runner: runner)
        let result = try await executor.run(request)
        emit("GATK execution completed with exit code \(result.exitCode).")
        emit("Provenance: \(result.provenanceURL.path)")
    }

    static func parseExtraArgs(_ extraArgs: String) throws -> [String] {
        do {
            return try AdvancedCommandLineOptions.parse(extraArgs)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    static func defaultToolVersion() -> String {
        PluginPack.builtInPack(id: "gatk-core")?
            .toolRequirements
            .first(where: { $0.environment == "gatk-core" })?
            .version ?? "unknown"
    }

    static func defaultRuntimeIdentity() -> GATKRuntimeIdentity {
        let condaEnvironment = CondaManager.shared.rootPrefix
            .appendingPathComponent("envs/gatk-core", isDirectory: true)
            .path
        return GATKRuntimeIdentity(condaEnvironment: condaEnvironment)
    }
}

protocol GATKCLIExecutableSubcommand {
    var execute: Bool { get }
    var dryRun: Bool { get }
}

extension GATKCLIExecutableSubcommand {
    var isDryRun: Bool {
        !execute || dryRun
    }
}

extension GATKCLICommand {
    struct HaplotypeCallerSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "haplotype-caller",
            abstract: "Construct a GATK HaplotypeCaller command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

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
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
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
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .haplotypeCaller(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct JointGenotypeSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "joint-genotype",
            abstract: "Construct GATK joint genotyping commands"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

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

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let strategy = GATKJointGenotypingStrategy(rawValue: combineStrategy) ?? .auto
            let config = GATKJointGenotypingConfiguration(
                referenceFASTAURL: URL(fileURLWithPath: reference),
                inputGVCFURLs: gvcfs.map { URL(fileURLWithPath: $0) },
                outputVCFURL: URL(fileURLWithPath: output),
                intermediateURL: URL(fileURLWithPath: intermediate),
                strategy: strategy,
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) },
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .jointGenotype(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct FilterSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "filter",
            abstract: "Construct a GATK VariantFiltration command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("preset"), help: "best-practices-snp, best-practices-indel, best-practices-both")
        var preset: String = GATKVariantFiltrationPreset.bestPracticesBoth.rawValue

        @Option(name: .customLong("output"), help: "Output filtered VCF path")
        var output: String

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let resolvedPreset = GATKVariantFiltrationPreset(rawValue: preset) ?? .bestPracticesBoth
            let config = GATKVariantFiltrationConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputVCFURL: URL(fileURLWithPath: output),
                preset: resolvedPreset,
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .variantFiltration(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct SelectSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "select",
            abstract: "Construct a GATK SelectVariants command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

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

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let variantType = type.flatMap { GATKSelectedVariantType(rawValue: $0.uppercased()) }
            let config = GATKSelectVariantsConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputVCFURL: URL(fileURLWithPath: output),
                sampleID: sample,
                variantType: variantType,
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) },
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .selectVariants(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct VariantsToTableSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "variants-to-table",
            abstract: "Construct a GATK VariantsToTable command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("fields"), help: "Comma-separated VCF fields")
        var fields: String = "CHROM,POS,REF,ALT,QUAL,AF,DP"

        @Option(name: .customLong("output"), help: "Output TSV path")
        var output: String

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
                throw ValidationError("Failed to parse gatk variants-to-table arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let config = GATKVariantsToTableConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputTableURL: URL(fileURLWithPath: output),
                fields: fields.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) },
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .variantsToTable(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct BQSRSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "bqsr",
            abstract: "Construct GATK BaseRecalibrator and ApplyBQSR commands"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("reference"), help: "Reference FASTA path")
        var reference: String

        @Option(name: .customLong("bam"), help: "Input BAM path")
        var bam: String

        @Option(name: .customLong("known-sites"), help: "Known-sites VCF path. Repeat for dbSNP, Mills, or cohort resources.")
        var knownSites: [String] = []

        @Option(name: .customLong("recal-table"), help: "Output recalibration table path")
        var recalTable: String

        @Option(name: .customLong("output"), help: "Output recalibrated BAM path")
        var output: String

        @Option(name: .customLong("intervals"), help: "Optional intervals BED/list/contig path")
        var intervals: String?

        @Option(name: .customLong("create-output-bam-index"), help: "Whether ApplyBQSR should create a BAM index")
        var createOutputBAMIndex: Bool = true

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK arguments appended to both BQSR commands"
        )
        var extraArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse gatk bqsr arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let config = GATKBaseQualityScoreRecalibrationConfiguration(
                referenceFASTAURL: URL(fileURLWithPath: reference),
                inputBAMURL: URL(fileURLWithPath: bam),
                outputBAMURL: URL(fileURLWithPath: output),
                knownSitesVCFURLs: knownSites.map { URL(fileURLWithPath: $0) },
                recalibrationTableURL: URL(fileURLWithPath: recalTable),
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) },
                createOutputBAMIndex: createOutputBAMIndex,
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .baseQualityScoreRecalibration(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct MarkDuplicatesSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "markdup",
            abstract: "Construct a GATK Picard MarkDuplicates command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("bam"), help: "Input BAM path. Repeat for multiple lanes.")
        var bams: [String] = []

        @Option(name: .customLong("output"), help: "Output duplicate-marked BAM path")
        var output: String

        @Option(name: .customLong("metrics"), help: "Output duplicate metrics path")
        var metrics: String

        @Option(name: .customLong("create-index"), help: "Whether MarkDuplicates should create a BAM index")
        var createIndex: Bool = true

        @Flag(name: .customLong("remove-duplicates"), help: "Remove duplicates instead of only marking them")
        var removeDuplicates: Bool = false

        @Option(name: .customLong("validation-stringency"), help: "Picard validation stringency, such as STRICT, LENIENT, or SILENT")
        var validationStringency: String?

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK/Picard arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse gatk markdup arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let config = GATKMarkDuplicatesConfiguration(
                inputBAMURLs: bams.map { URL(fileURLWithPath: $0) },
                outputBAMURL: URL(fileURLWithPath: output),
                metricsURL: URL(fileURLWithPath: metrics),
                createIndex: createIndex,
                removeDuplicates: removeDuplicates,
                validationStringency: validationStringency,
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .markDuplicates(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct ValidateSamSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "validate-sam",
            abstract: "Construct a GATK Picard ValidateSamFile command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("bam"), help: "Input BAM/SAM/CRAM path")
        var bam: String

        @Option(name: .customLong("output"), help: "Optional output validation report path")
        var output: String?

        @Option(name: .customLong("reference"), help: "Optional reference FASTA path")
        var reference: String?

        @Option(name: .customLong("mode"), help: "Validation mode: SUMMARY or VERBOSE")
        var mode: String = GATKValidateSamFileMode.summary.rawValue

        @Option(name: .customLong("validate-index"), help: "Whether ValidateSamFile should validate the BAM index")
        var validateIndex: Bool = true

        @Option(name: .customLong("ignore-warnings"), help: "Whether warnings should be ignored")
        var ignoreWarnings: Bool = false

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK/Picard arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse gatk validate-sam arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let resolvedMode = GATKValidateSamFileMode(rawValue: mode.uppercased()) ?? .summary
            let config = GATKValidateSamFileConfiguration(
                inputBAMURL: URL(fileURLWithPath: bam),
                outputReportURL: output.map { URL(fileURLWithPath: $0) },
                referenceFASTAURL: reference.map { URL(fileURLWithPath: $0) },
                mode: resolvedMode,
                validateIndex: validateIndex,
                ignoreWarnings: ignoreWarnings,
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .validateSamFile(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct LeftAlignSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "leftalign",
            abstract: "Construct a GATK LeftAlignAndTrimVariants command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("reference"), help: "Reference FASTA path")
        var reference: String

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("output"), help: "Output left-aligned VCF path")
        var output: String

        @Option(name: .customLong("intervals"), help: "Optional intervals BED/list/contig path")
        var intervals: String?

        @Flag(name: .customLong("split-multi-allelics"), help: "Split multi-allelic records")
        var splitMultiAllelics: Bool = false

        @Option(name: .customLong("max-indel-length"), help: "Maximum indel length to consider")
        var maxIndelLength: Int = 200

        @Option(name: .customLong("max-leading-bases"), help: "Maximum leading bases for left alignment")
        var maxLeadingBases: Int = 1000

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
                throw ValidationError("Failed to parse gatk leftalign arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let config = GATKLeftAlignAndTrimVariantsConfiguration(
                referenceFASTAURL: URL(fileURLWithPath: reference),
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputVCFURL: URL(fileURLWithPath: output),
                intervalsURL: intervals.map { URL(fileURLWithPath: $0) },
                splitMultiAllelics: splitMultiAllelics,
                maxIndelLength: maxIndelLength,
                maxLeadingBases: maxLeadingBases,
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .leftAlignAndTrimVariants(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }

    struct CollectMetricsSubcommand: AsyncParsableCommand, GATKCLIExecutableSubcommand {
        static let configuration = CommandConfiguration(
            commandName: "collect-metrics",
            abstract: "Construct a GATK Picard CollectVariantCallingMetrics command"
        )

        @Flag(name: .customLong("execute"), help: "Run GATK and write final-location provenance.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Print the GATK command preview without running it.")
        var dryRun: Bool = false

        @Option(name: .customLong("vcf"), help: "Input VCF path")
        var vcf: String

        @Option(name: .customLong("output-prefix"), help: "Output metrics prefix path")
        var outputPrefix: String

        @Option(name: .customLong("dbsnp"), help: "dbSNP VCF path")
        var dbsnp: String

        @Option(name: .customLong("sequence-dictionary"), help: "Optional reference sequence dictionary path")
        var sequenceDictionary: String?

        @Flag(name: .customLong("gvcf-input"), help: "Treat input as a GVCF")
        var gvcfInput: Bool = false

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional GATK/Picard arguments, written exactly as they should be passed"
        )
        var extraArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse gatk collect-metrics arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await executeForTesting(
                emit: emit,
                runner: ManagedGATKCommandRunner(),
                toolVersion: GATKCLICommand.defaultToolVersion(),
                runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity()
            )
        }

        func executeForTesting<Runner: GATKCommandRunning>(
            emit: @escaping (String) -> Void,
            runner: Runner,
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) async throws {
            try await GATKCLICommand.runOrPreview(
                request: executionRequest(
                    toolVersion: toolVersion,
                    runtimeIdentity: runtimeIdentity,
                    packVersion: packVersion
                ),
                execute: execute && !dryRun,
                runner: runner,
                emit: emit
            )
        }

        func executionRequest(
            toolVersion: String,
            runtimeIdentity: GATKRuntimeIdentity,
            packVersion: String? = nil
        ) throws -> GATKPipelineExecutionRequest {
            let config = GATKCollectVariantCallingMetricsConfiguration(
                inputVCFURL: URL(fileURLWithPath: vcf),
                outputMetricsPrefixURL: URL(fileURLWithPath: outputPrefix),
                dbSNPVCFURL: URL(fileURLWithPath: dbsnp),
                sequenceDictionaryURL: sequenceDictionary.map { URL(fileURLWithPath: $0) },
                isGVCFInput: gvcfInput,
                extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
            )
            return .collectVariantCallingMetrics(
                configuration: config,
                toolVersion: toolVersion,
                runtimeIdentity: runtimeIdentity,
                packVersion: packVersion
            )
        }
    }
}
