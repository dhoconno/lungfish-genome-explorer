// GATKCommandBuilder.swift - Pure command construction for first-class GATK wrappers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct GATKCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: String
    public let workingDirectory: URL?

    public init(
        executable: String = "gatk",
        arguments: [String],
        environment: String = "gatk-core",
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public var shellCommand: String {
        ([executable] + arguments).map(shellEscape).joined(separator: " ")
    }
}

public enum GATKEmitReferenceConfidence: String, Sendable, Codable, Equatable {
    case gvcf = "GVCF"
    case none = "NONE"
}

public struct GATKHaplotypeCallerConfiguration: Sendable, Codable, Equatable {
    public let referenceFASTAURL: URL
    public let inputBAMURL: URL
    public let outputVCFURL: URL
    public let emitReferenceConfidence: GATKEmitReferenceConfidence
    public let ploidy: Int
    public let intervalsURL: URL?
    public let pcrIndelModel: String
    public let standardMinConfidenceThresholdForCalling: Double
    public let maxAlternateAlleles: Int
    public let nativePairHMMThreads: Int
    public let extraArguments: [String]

    public init(
        referenceFASTAURL: URL,
        inputBAMURL: URL,
        outputVCFURL: URL,
        emitReferenceConfidence: GATKEmitReferenceConfidence = .gvcf,
        ploidy: Int = 2,
        intervalsURL: URL? = nil,
        pcrIndelModel: String = "CONSERVATIVE",
        standardMinConfidenceThresholdForCalling: Double = 30.0,
        maxAlternateAlleles: Int = 6,
        nativePairHMMThreads: Int = 4,
        extraArguments: [String] = []
    ) {
        self.referenceFASTAURL = referenceFASTAURL
        self.inputBAMURL = inputBAMURL
        self.outputVCFURL = outputVCFURL
        self.emitReferenceConfidence = emitReferenceConfidence
        self.ploidy = ploidy
        self.intervalsURL = intervalsURL
        self.pcrIndelModel = pcrIndelModel
        self.standardMinConfidenceThresholdForCalling = standardMinConfidenceThresholdForCalling
        self.maxAlternateAlleles = maxAlternateAlleles
        self.nativePairHMMThreads = nativePairHMMThreads
        self.extraArguments = extraArguments
    }
}

public enum GATKJointGenotypingStrategy: String, Sendable, Codable, Equatable {
    case auto
    case combineGVCFs = "combine-gvcfs"
    case genomicsDB = "genomicsdb"
}

public struct GATKJointGenotypingConfiguration: Sendable, Codable, Equatable {
    public let referenceFASTAURL: URL
    public let inputGVCFURLs: [URL]
    public let outputVCFURL: URL
    public let intermediateURL: URL
    public let strategy: GATKJointGenotypingStrategy
    public let intervalsURL: URL?
    public let standardMinConfidenceThresholdForCalling: Double
    public let alleleSpecificAnnotations: Bool
    public let extraArguments: [String]

    public init(
        referenceFASTAURL: URL,
        inputGVCFURLs: [URL],
        outputVCFURL: URL,
        intermediateURL: URL,
        strategy: GATKJointGenotypingStrategy = .auto,
        intervalsURL: URL? = nil,
        standardMinConfidenceThresholdForCalling: Double = 30.0,
        alleleSpecificAnnotations: Bool = true,
        extraArguments: [String] = []
    ) {
        self.referenceFASTAURL = referenceFASTAURL
        self.inputGVCFURLs = inputGVCFURLs
        self.outputVCFURL = outputVCFURL
        self.intermediateURL = intermediateURL
        self.strategy = strategy
        self.intervalsURL = intervalsURL
        self.standardMinConfidenceThresholdForCalling = standardMinConfidenceThresholdForCalling
        self.alleleSpecificAnnotations = alleleSpecificAnnotations
        self.extraArguments = extraArguments
    }
}

public struct GATKVariantFilter: Sendable, Codable, Equatable {
    public let name: String
    public let expression: String

    public init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

public enum GATKVariantFiltrationPreset: String, Sendable, Codable, Equatable {
    case bestPracticesSNP = "best-practices-snp"
    case bestPracticesIndel = "best-practices-indel"
    case bestPracticesBoth = "best-practices-both"
    case custom

    public var filters: [GATKVariantFilter] {
        switch self {
        case .bestPracticesSNP:
            return Self.snpFilters
        case .bestPracticesIndel:
            return Self.indelFilters
        case .bestPracticesBoth:
            return Self.snpFilters + Self.indelFilters
        case .custom:
            return []
        }
    }

    private static let snpFilters = [
        GATKVariantFilter(name: "QD2", expression: "QD < 2.0"),
        GATKVariantFilter(name: "FS60", expression: "FS > 60.0"),
        GATKVariantFilter(name: "MQ40", expression: "MQ < 40.0"),
        GATKVariantFilter(name: "MQRankSum-12.5", expression: "MQRankSum < -12.5"),
        GATKVariantFilter(name: "ReadPosRankSum-8", expression: "ReadPosRankSum < -8.0"),
        GATKVariantFilter(name: "SOR3", expression: "SOR > 3.0"),
    ]

    private static let indelFilters = [
        GATKVariantFilter(name: "QD2", expression: "QD < 2.0"),
        GATKVariantFilter(name: "FS200", expression: "FS > 200.0"),
        GATKVariantFilter(name: "ReadPosRankSum-20", expression: "ReadPosRankSum < -20.0"),
        GATKVariantFilter(name: "SOR10", expression: "SOR > 10.0"),
    ]
}

public struct GATKVariantFiltrationConfiguration: Sendable, Codable, Equatable {
    public let inputVCFURL: URL
    public let outputVCFURL: URL
    public let filters: [GATKVariantFilter]
    public let extraArguments: [String]

    public init(
        inputVCFURL: URL,
        outputVCFURL: URL,
        preset: GATKVariantFiltrationPreset = .bestPracticesBoth,
        customFilters: [GATKVariantFilter] = [],
        extraArguments: [String] = []
    ) {
        self.inputVCFURL = inputVCFURL
        self.outputVCFURL = outputVCFURL
        self.filters = preset == .custom ? customFilters : preset.filters
        self.extraArguments = extraArguments
    }
}

public enum GATKSelectedVariantType: String, Sendable, Codable, Equatable {
    case snp = "SNP"
    case indel = "INDEL"
    case mixed = "MIXED"
}

public struct GATKSelectVariantsConfiguration: Sendable, Codable, Equatable {
    public let inputVCFURL: URL
    public let outputVCFURL: URL
    public let sampleID: String?
    public let variantType: GATKSelectedVariantType?
    public let intervalsURL: URL?
    public let extraArguments: [String]

    public init(
        inputVCFURL: URL,
        outputVCFURL: URL,
        sampleID: String? = nil,
        variantType: GATKSelectedVariantType? = nil,
        intervalsURL: URL? = nil,
        extraArguments: [String] = []
    ) {
        self.inputVCFURL = inputVCFURL
        self.outputVCFURL = outputVCFURL
        self.sampleID = sampleID
        self.variantType = variantType
        self.intervalsURL = intervalsURL
        self.extraArguments = extraArguments
    }
}

public struct GATKVariantsToTableConfiguration: Sendable, Codable, Equatable {
    public let inputVCFURL: URL
    public let outputTableURL: URL
    public let fields: [String]
    public let extraArguments: [String]

    public init(
        inputVCFURL: URL,
        outputTableURL: URL,
        fields: [String] = ["CHROM", "POS", "REF", "ALT", "QUAL", "AF", "DP"],
        extraArguments: [String] = []
    ) {
        self.inputVCFURL = inputVCFURL
        self.outputTableURL = outputTableURL
        self.fields = fields
        self.extraArguments = extraArguments
    }
}

public struct GATKBaseQualityScoreRecalibrationConfiguration: Sendable, Codable, Equatable {
    public let referenceFASTAURL: URL
    public let inputBAMURL: URL
    public let outputBAMURL: URL
    public let knownSitesVCFURLs: [URL]
    public let recalibrationTableURL: URL
    public let intervalsURL: URL?
    public let createOutputBAMIndex: Bool
    public let extraArguments: [String]

    public init(
        referenceFASTAURL: URL,
        inputBAMURL: URL,
        outputBAMURL: URL,
        knownSitesVCFURLs: [URL],
        recalibrationTableURL: URL,
        intervalsURL: URL? = nil,
        createOutputBAMIndex: Bool = true,
        extraArguments: [String] = []
    ) {
        self.referenceFASTAURL = referenceFASTAURL
        self.inputBAMURL = inputBAMURL
        self.outputBAMURL = outputBAMURL
        self.knownSitesVCFURLs = knownSitesVCFURLs
        self.recalibrationTableURL = recalibrationTableURL
        self.intervalsURL = intervalsURL
        self.createOutputBAMIndex = createOutputBAMIndex
        self.extraArguments = extraArguments
    }
}

public struct GATKMarkDuplicatesConfiguration: Sendable, Codable, Equatable {
    public let inputBAMURLs: [URL]
    public let outputBAMURL: URL
    public let metricsURL: URL
    public let createIndex: Bool
    public let removeDuplicates: Bool
    public let validationStringency: String?
    public let extraArguments: [String]

    public init(
        inputBAMURLs: [URL],
        outputBAMURL: URL,
        metricsURL: URL,
        createIndex: Bool = true,
        removeDuplicates: Bool = false,
        validationStringency: String? = nil,
        extraArguments: [String] = []
    ) {
        self.inputBAMURLs = inputBAMURLs
        self.outputBAMURL = outputBAMURL
        self.metricsURL = metricsURL
        self.createIndex = createIndex
        self.removeDuplicates = removeDuplicates
        self.validationStringency = validationStringency
        self.extraArguments = extraArguments
    }
}

public enum GATKValidateSamFileMode: String, Sendable, Codable, Equatable {
    case summary = "SUMMARY"
    case verbose = "VERBOSE"
}

public struct GATKValidateSamFileConfiguration: Sendable, Codable, Equatable {
    public let inputBAMURL: URL
    public let outputReportURL: URL?
    public let referenceFASTAURL: URL?
    public let mode: GATKValidateSamFileMode
    public let validateIndex: Bool
    public let ignoreWarnings: Bool
    public let extraArguments: [String]

    public init(
        inputBAMURL: URL,
        outputReportURL: URL? = nil,
        referenceFASTAURL: URL? = nil,
        mode: GATKValidateSamFileMode = .summary,
        validateIndex: Bool = true,
        ignoreWarnings: Bool = false,
        extraArguments: [String] = []
    ) {
        self.inputBAMURL = inputBAMURL
        self.outputReportURL = outputReportURL
        self.referenceFASTAURL = referenceFASTAURL
        self.mode = mode
        self.validateIndex = validateIndex
        self.ignoreWarnings = ignoreWarnings
        self.extraArguments = extraArguments
    }
}

public struct GATKLeftAlignAndTrimVariantsConfiguration: Sendable, Codable, Equatable {
    public let referenceFASTAURL: URL
    public let inputVCFURL: URL
    public let outputVCFURL: URL
    public let intervalsURL: URL?
    public let splitMultiAllelics: Bool
    public let maxIndelLength: Int
    public let maxLeadingBases: Int
    public let extraArguments: [String]

    public init(
        referenceFASTAURL: URL,
        inputVCFURL: URL,
        outputVCFURL: URL,
        intervalsURL: URL? = nil,
        splitMultiAllelics: Bool = false,
        maxIndelLength: Int = 200,
        maxLeadingBases: Int = 1000,
        extraArguments: [String] = []
    ) {
        self.referenceFASTAURL = referenceFASTAURL
        self.inputVCFURL = inputVCFURL
        self.outputVCFURL = outputVCFURL
        self.intervalsURL = intervalsURL
        self.splitMultiAllelics = splitMultiAllelics
        self.maxIndelLength = maxIndelLength
        self.maxLeadingBases = maxLeadingBases
        self.extraArguments = extraArguments
    }
}

public struct GATKCollectVariantCallingMetricsConfiguration: Sendable, Codable, Equatable {
    public let inputVCFURL: URL
    public let outputMetricsPrefixURL: URL
    public let dbSNPVCFURL: URL
    public let sequenceDictionaryURL: URL?
    public let isGVCFInput: Bool
    public let extraArguments: [String]

    public init(
        inputVCFURL: URL,
        outputMetricsPrefixURL: URL,
        dbSNPVCFURL: URL,
        sequenceDictionaryURL: URL? = nil,
        isGVCFInput: Bool = false,
        extraArguments: [String] = []
    ) {
        self.inputVCFURL = inputVCFURL
        self.outputMetricsPrefixURL = outputMetricsPrefixURL
        self.dbSNPVCFURL = dbSNPVCFURL
        self.sequenceDictionaryURL = sequenceDictionaryURL
        self.isGVCFInput = isGVCFInput
        self.extraArguments = extraArguments
    }
}

public enum GATKCommandBuilder {
    public static let jointGenotypingCombineGVCFsThreshold = 50

    public static func haplotypeCallerCommand(_ config: GATKHaplotypeCallerConfiguration) -> GATKCommand {
        var arguments = [
            "HaplotypeCaller",
            "-R", config.referenceFASTAURL.path,
            "-I", config.inputBAMURL.path,
            "-O", config.outputVCFURL.path,
            "--sample-ploidy", String(config.ploidy),
            "--max-alternate-alleles", String(config.maxAlternateAlleles),
            "--pcr-indel-model", config.pcrIndelModel,
            "--native-pair-hmm-threads", String(config.nativePairHMMThreads),
        ]
        if config.emitReferenceConfidence != .none {
            arguments += ["-ERC", config.emitReferenceConfidence.rawValue]
        } else {
            arguments += [
                "--standard-min-confidence-threshold-for-calling",
                format(config.standardMinConfidenceThresholdForCalling)
            ]
        }
        if let intervalsURL = config.intervalsURL {
            arguments += ["-L", intervalsURL.path]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputVCFURL.deletingLastPathComponent())
    }

    public static func resolvedJointGenotypingStrategy(
        sampleCount: Int,
        requested: GATKJointGenotypingStrategy
    ) -> GATKJointGenotypingStrategy {
        guard requested == .auto else { return requested }
        return sampleCount <= jointGenotypingCombineGVCFsThreshold ? .combineGVCFs : .genomicsDB
    }

    public static func jointGenotypingCommands(_ config: GATKJointGenotypingConfiguration) -> [GATKCommand] {
        switch resolvedJointGenotypingStrategy(sampleCount: config.inputGVCFURLs.count, requested: config.strategy) {
        case .auto:
            return jointGenotypingCommands(config)
        case .combineGVCFs:
            return combineGVCFsCommands(config)
        case .genomicsDB:
            return genomicsDBCommands(config)
        }
    }

    public static func variantFiltrationCommand(_ config: GATKVariantFiltrationConfiguration) -> GATKCommand {
        var arguments = [
            "VariantFiltration",
            "-V", config.inputVCFURL.path,
            "-O", config.outputVCFURL.path,
        ]
        for filter in config.filters {
            arguments += ["--filter-expression", filter.expression, "--filter-name", filter.name]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputVCFURL.deletingLastPathComponent())
    }

    public static func selectVariantsCommand(_ config: GATKSelectVariantsConfiguration) -> GATKCommand {
        var arguments = [
            "SelectVariants",
            "-V", config.inputVCFURL.path,
            "-O", config.outputVCFURL.path,
        ]
        if let sampleID = config.sampleID {
            arguments += ["-sn", sampleID]
        }
        if let variantType = config.variantType {
            arguments += ["-select-type", variantType.rawValue]
        }
        if let intervalsURL = config.intervalsURL {
            arguments += ["-L", intervalsURL.path]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputVCFURL.deletingLastPathComponent())
    }

    public static func variantsToTableCommand(_ config: GATKVariantsToTableConfiguration) -> GATKCommand {
        var arguments = [
            "VariantsToTable",
            "-V", config.inputVCFURL.path,
            "-O", config.outputTableURL.path,
        ]
        for field in config.fields {
            arguments += ["-F", field]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputTableURL.deletingLastPathComponent())
    }

    public static func baseQualityScoreRecalibrationCommands(
        _ config: GATKBaseQualityScoreRecalibrationConfiguration
    ) -> [GATKCommand] {
        var recalibratorArguments = [
            "BaseRecalibrator",
            "-R", config.referenceFASTAURL.path,
            "-I", config.inputBAMURL.path,
            "-O", config.recalibrationTableURL.path,
        ]
        for knownSitesURL in config.knownSitesVCFURLs {
            recalibratorArguments += ["--known-sites", knownSitesURL.path]
        }
        if let intervalsURL = config.intervalsURL {
            recalibratorArguments += ["-L", intervalsURL.path]
        }
        recalibratorArguments += config.extraArguments

        var applyArguments = [
            "ApplyBQSR",
            "-R", config.referenceFASTAURL.path,
            "-I", config.inputBAMURL.path,
            "--bqsr-recal-file", config.recalibrationTableURL.path,
            "-O", config.outputBAMURL.path,
            "--create-output-bam-index", String(config.createOutputBAMIndex),
        ]
        if let intervalsURL = config.intervalsURL {
            applyArguments += ["-L", intervalsURL.path]
        }
        applyArguments += config.extraArguments

        return [
            GATKCommand(arguments: recalibratorArguments, workingDirectory: config.recalibrationTableURL.deletingLastPathComponent()),
            GATKCommand(arguments: applyArguments, workingDirectory: config.outputBAMURL.deletingLastPathComponent()),
        ]
    }

    public static func markDuplicatesCommand(_ config: GATKMarkDuplicatesConfiguration) -> GATKCommand {
        var arguments = ["MarkDuplicates"]
        for inputBAMURL in config.inputBAMURLs {
            arguments += ["-I", inputBAMURL.path]
        }
        arguments += [
            "-O", config.outputBAMURL.path,
            "-M", config.metricsURL.path,
            "--CREATE_INDEX", String(config.createIndex),
            "--REMOVE_DUPLICATES", String(config.removeDuplicates),
        ]
        if let validationStringency = config.validationStringency {
            arguments += ["--VALIDATION_STRINGENCY", validationStringency]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputBAMURL.deletingLastPathComponent())
    }

    public static func validateSamFileCommand(_ config: GATKValidateSamFileConfiguration) -> GATKCommand {
        var arguments = [
            "ValidateSamFile",
            "-I", config.inputBAMURL.path,
            "--MODE", config.mode.rawValue,
            "--VALIDATE_INDEX", String(config.validateIndex),
            "--IGNORE_WARNINGS", String(config.ignoreWarnings),
        ]
        if let outputReportURL = config.outputReportURL {
            arguments += ["-O", outputReportURL.path]
        }
        if let referenceFASTAURL = config.referenceFASTAURL {
            arguments += ["-R", referenceFASTAURL.path]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputReportURL?.deletingLastPathComponent())
    }

    public static func leftAlignAndTrimVariantsCommand(
        _ config: GATKLeftAlignAndTrimVariantsConfiguration
    ) -> GATKCommand {
        var arguments = [
            "LeftAlignAndTrimVariants",
            "-R", config.referenceFASTAURL.path,
            "-V", config.inputVCFURL.path,
            "-O", config.outputVCFURL.path,
            "--split-multi-allelics", String(config.splitMultiAllelics),
            "--max-indel-length", String(config.maxIndelLength),
            "--max-leading-bases", String(config.maxLeadingBases),
        ]
        if let intervalsURL = config.intervalsURL {
            arguments += ["-L", intervalsURL.path]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputVCFURL.deletingLastPathComponent())
    }

    public static func collectVariantCallingMetricsCommand(
        _ config: GATKCollectVariantCallingMetricsConfiguration
    ) -> GATKCommand {
        var arguments = [
            "CollectVariantCallingMetrics",
            "-I", config.inputVCFURL.path,
            "-O", config.outputMetricsPrefixURL.path,
            "--DBSNP", config.dbSNPVCFURL.path,
        ]
        if let sequenceDictionaryURL = config.sequenceDictionaryURL {
            arguments += ["--SEQUENCE_DICTIONARY", sequenceDictionaryURL.path]
        }
        if config.isGVCFInput {
            arguments += ["--GVCF_INPUT", "true"]
        }
        arguments += config.extraArguments
        return GATKCommand(arguments: arguments, workingDirectory: config.outputMetricsPrefixURL.deletingLastPathComponent())
    }

    private static func combineGVCFsCommands(_ config: GATKJointGenotypingConfiguration) -> [GATKCommand] {
        var combineArguments = [
            "CombineGVCFs",
            "-R", config.referenceFASTAURL.path,
            "-O", config.intermediateURL.path,
        ]
        for gvcfURL in config.inputGVCFURLs {
            combineArguments += ["--variant", gvcfURL.path]
        }
        if let intervalsURL = config.intervalsURL {
            combineArguments += ["-L", intervalsURL.path]
        }

        var genotypeArguments = genotypeGVCFsBaseArguments(
            referenceFASTAURL: config.referenceFASTAURL,
            variantValue: config.intermediateURL.path,
            outputVCFURL: config.outputVCFURL,
            confidence: config.standardMinConfidenceThresholdForCalling,
            alleleSpecificAnnotations: config.alleleSpecificAnnotations
        )
        if let intervalsURL = config.intervalsURL {
            genotypeArguments += ["-L", intervalsURL.path]
        }
        genotypeArguments += config.extraArguments
        return [
            GATKCommand(arguments: combineArguments, workingDirectory: config.intermediateURL.deletingLastPathComponent()),
            GATKCommand(arguments: genotypeArguments, workingDirectory: config.outputVCFURL.deletingLastPathComponent()),
        ]
    }

    private static func genomicsDBCommands(_ config: GATKJointGenotypingConfiguration) -> [GATKCommand] {
        var importArguments = [
            "GenomicsDBImport",
            "--genomicsdb-workspace-path", config.intermediateURL.path,
        ]
        for gvcfURL in config.inputGVCFURLs {
            importArguments += ["-V", gvcfURL.path]
        }
        if let intervalsURL = config.intervalsURL {
            importArguments += ["-L", intervalsURL.path]
        }

        var genotypeArguments = genotypeGVCFsBaseArguments(
            referenceFASTAURL: config.referenceFASTAURL,
            variantValue: "gendb://\(config.intermediateURL.path)",
            outputVCFURL: config.outputVCFURL,
            confidence: config.standardMinConfidenceThresholdForCalling,
            alleleSpecificAnnotations: config.alleleSpecificAnnotations
        )
        if let intervalsURL = config.intervalsURL {
            genotypeArguments += ["-L", intervalsURL.path]
        }
        genotypeArguments += config.extraArguments
        return [
            GATKCommand(arguments: importArguments, workingDirectory: config.intermediateURL.deletingLastPathComponent()),
            GATKCommand(arguments: genotypeArguments, workingDirectory: config.outputVCFURL.deletingLastPathComponent()),
        ]
    }

    private static func genotypeGVCFsBaseArguments(
        referenceFASTAURL: URL,
        variantValue: String,
        outputVCFURL: URL,
        confidence: Double,
        alleleSpecificAnnotations: Bool
    ) -> [String] {
        var arguments = [
            "GenotypeGVCFs",
            "-R", referenceFASTAURL.path,
            "-V", variantValue,
            "-O", outputVCFURL.path,
            "--standard-min-confidence-threshold-for-calling", format(confidence),
        ]
        if alleleSpecificAnnotations {
            arguments += ["-G", "AS_StandardAnnotation"]
        }
        return arguments
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
