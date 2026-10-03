// GATKPipelineExecutionRequest.swift - Everything needed to run and record a GATK pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct GATKPipelineExecutionRequest: Sendable, Equatable {
    public let workflowName: String
    public let toolName: String
    public let toolVersion: String
    public let commands: [GATKCommand]
    public let outputDirectory: URL
    public let inputs: [GATKFileArtifact]
    public let outputs: [GATKFileArtifact]
    public let options: [String: String]
    public let resolvedDefaults: [String: String]
    public let runtimeIdentity: GATKRuntimeIdentity
    public let packID: String?
    public let packVersion: String?

    public init(
        workflowName: String,
        toolName: String,
        toolVersion: String,
        command: GATKCommand,
        outputDirectory: URL,
        inputs: [GATKFileArtifact],
        outputs: [GATKFileArtifact],
        options: [String: String],
        resolvedDefaults: [String: String],
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = nil,
        packVersion: String? = nil
    ) {
        self.init(
            workflowName: workflowName,
            toolName: toolName,
            toolVersion: toolVersion,
            commands: [command],
            outputDirectory: outputDirectory,
            inputs: inputs,
            outputs: outputs,
            options: options,
            resolvedDefaults: resolvedDefaults,
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    public init(
        workflowName: String,
        toolName: String,
        toolVersion: String,
        commands: [GATKCommand],
        outputDirectory: URL,
        inputs: [GATKFileArtifact],
        outputs: [GATKFileArtifact],
        options: [String: String],
        resolvedDefaults: [String: String],
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = nil,
        packVersion: String? = nil
    ) {
        precondition(!commands.isEmpty, "GATK execution requests require at least one command.")
        self.workflowName = workflowName
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.commands = commands
        self.outputDirectory = outputDirectory
        self.inputs = inputs
        self.outputs = outputs
        self.options = options
        self.resolvedDefaults = resolvedDefaults
        self.runtimeIdentity = runtimeIdentity
        self.packID = packID
        self.packVersion = packVersion
    }

    public var command: GATKCommand {
        commands[0]
    }
}

public extension GATKPipelineExecutionRequest {
    static func haplotypeCaller(
        configuration: GATKHaplotypeCallerConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        let command = GATKCommandBuilder.haplotypeCallerCommand(configuration)
        var inputs = [
            GATKFileArtifact(url: configuration.referenceFASTAURL, format: .fasta, role: .reference),
            GATKFileArtifact(url: configuration.inputBAMURL, format: .bam, role: .input),
        ]
        if let intervalsURL = configuration.intervalsURL {
            inputs.append(GATKFileArtifact(url: intervalsURL, role: .input))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK HaplotypeCaller",
            toolName: "gatk-haplotype-caller",
            toolVersion: toolVersion,
            command: command,
            outputDirectory: configuration.outputVCFURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: [GATKFileArtifact(url: configuration.outputVCFURL, format: .vcf, role: .output)],
            options: [
                "emitReferenceConfidence": configuration.emitReferenceConfidence.rawValue,
                "ploidy": String(configuration.ploidy),
                "pcrIndelModel": configuration.pcrIndelModel,
                "standardMinConfidenceThresholdForCalling": format(configuration.standardMinConfidenceThresholdForCalling),
                "maxAlternateAlleles": String(configuration.maxAlternateAlleles),
                "nativePairHMMThreads": String(configuration.nativePairHMMThreads),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "emitReferenceConfidence": GATKEmitReferenceConfidence.gvcf.rawValue,
                "ploidy": "2",
                "pcrIndelModel": "CONSERVATIVE",
                "standardMinConfidenceThresholdForCalling": "30.0",
                "maxAlternateAlleles": "6",
                "nativePairHMMThreads": "4",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func jointGenotype(
        configuration: GATKJointGenotypingConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        var inputs = [
            GATKFileArtifact(url: configuration.referenceFASTAURL, format: .fasta, role: .reference),
        ] + configuration.inputGVCFURLs.map {
            GATKFileArtifact(url: $0, format: .vcf, role: .input)
        }
        if let intervalsURL = configuration.intervalsURL {
            inputs.append(GATKFileArtifact(url: intervalsURL, role: .input))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK Joint Genotyping",
            toolName: "gatk-joint-genotype",
            toolVersion: toolVersion,
            commands: GATKCommandBuilder.jointGenotypingCommands(configuration),
            outputDirectory: configuration.outputVCFURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: [
                GATKFileArtifact(url: configuration.intermediateURL, format: .vcf, role: .output),
                GATKFileArtifact(url: configuration.outputVCFURL, format: .vcf, role: .output),
            ],
            options: [
                "combineStrategy": configuration.strategy.rawValue,
                "inputGVCFCount": String(configuration.inputGVCFURLs.count),
                "intervals": configuration.intervalsURL?.path ?? "",
                "standardMinConfidenceThresholdForCalling": format(configuration.standardMinConfidenceThresholdForCalling),
                "alleleSpecificAnnotations": String(configuration.alleleSpecificAnnotations),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "combineStrategy": GATKJointGenotypingStrategy.auto.rawValue,
                "intervals": "",
                "standardMinConfidenceThresholdForCalling": "30.0",
                "alleleSpecificAnnotations": "true",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func variantFiltration(
        configuration: GATKVariantFiltrationConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        GATKPipelineExecutionRequest(
            workflowName: "GATK VariantFiltration",
            toolName: "gatk-variant-filtration",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.variantFiltrationCommand(configuration),
            outputDirectory: configuration.outputVCFURL.deletingLastPathComponent(),
            inputs: [GATKFileArtifact(url: configuration.inputVCFURL, format: .vcf, role: .input)],
            outputs: [GATKFileArtifact(url: configuration.outputVCFURL, format: .vcf, role: .output)],
            options: [
                "filters": configuration.filters.map { "\($0.name)=\($0.expression)" }.joined(separator: ";"),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "preset": GATKVariantFiltrationPreset.bestPracticesBoth.rawValue,
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func selectVariants(
        configuration: GATKSelectVariantsConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        var inputs = [GATKFileArtifact(url: configuration.inputVCFURL, format: .vcf, role: .input)]
        if let intervalsURL = configuration.intervalsURL {
            inputs.append(GATKFileArtifact(url: intervalsURL, role: .input))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK SelectVariants",
            toolName: "gatk-select-variants",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.selectVariantsCommand(configuration),
            outputDirectory: configuration.outputVCFURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: [GATKFileArtifact(url: configuration.outputVCFURL, format: .vcf, role: .output)],
            options: [
                "sampleID": configuration.sampleID ?? "",
                "variantType": configuration.variantType?.rawValue ?? "",
                "intervals": configuration.intervalsURL?.path ?? "",
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "sampleID": "",
                "variantType": "",
                "intervals": "",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func variantsToTable(
        configuration: GATKVariantsToTableConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        GATKPipelineExecutionRequest(
            workflowName: "GATK VariantsToTable",
            toolName: "gatk-variants-to-table",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.variantsToTableCommand(configuration),
            outputDirectory: configuration.outputTableURL.deletingLastPathComponent(),
            inputs: [GATKFileArtifact(url: configuration.inputVCFURL, format: .vcf, role: .input)],
            outputs: [GATKFileArtifact(url: configuration.outputTableURL, format: .text, role: .output)],
            options: [
                "fields": jsonArrayString(configuration.fields),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "fields": jsonArrayString(["CHROM", "POS", "REF", "ALT", "QUAL", "AF", "DP"]),
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func baseQualityScoreRecalibration(
        configuration: GATKBaseQualityScoreRecalibrationConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        var inputs = [
            GATKFileArtifact(url: configuration.referenceFASTAURL, format: .fasta, role: .reference),
            GATKFileArtifact(url: configuration.inputBAMURL, format: .bam, role: .input),
        ] + configuration.knownSitesVCFURLs.map {
            GATKFileArtifact(url: $0, format: .vcf, role: .reference)
        }
        if let intervalsURL = configuration.intervalsURL {
            inputs.append(GATKFileArtifact(url: intervalsURL, role: .input))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK Base Quality Score Recalibration",
            toolName: "gatk-bqsr",
            toolVersion: toolVersion,
            commands: GATKCommandBuilder.baseQualityScoreRecalibrationCommands(configuration),
            outputDirectory: configuration.outputBAMURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: [
                GATKFileArtifact(url: configuration.recalibrationTableURL, format: .text, role: .output),
                GATKFileArtifact(url: configuration.outputBAMURL, format: .bam, role: .output),
            ],
            options: [
                "knownSitesCount": String(configuration.knownSitesVCFURLs.count),
                "intervals": configuration.intervalsURL?.path ?? "",
                "createOutputBAMIndex": String(configuration.createOutputBAMIndex),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "intervals": "",
                "createOutputBAMIndex": "true",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func markDuplicates(
        configuration: GATKMarkDuplicatesConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        GATKPipelineExecutionRequest(
            workflowName: "GATK MarkDuplicates",
            toolName: "gatk-mark-duplicates",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.markDuplicatesCommand(configuration),
            outputDirectory: configuration.outputBAMURL.deletingLastPathComponent(),
            inputs: configuration.inputBAMURLs.map {
                GATKFileArtifact(url: $0, format: .bam, role: .input)
            },
            outputs: [
                GATKFileArtifact(url: configuration.outputBAMURL, format: .bam, role: .output),
                GATKFileArtifact(url: configuration.metricsURL, format: .text, role: .report),
            ],
            options: [
                "inputBAMCount": String(configuration.inputBAMURLs.count),
                "createIndex": String(configuration.createIndex),
                "removeDuplicates": String(configuration.removeDuplicates),
                "validationStringency": configuration.validationStringency ?? "",
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "createIndex": "true",
                "removeDuplicates": "false",
                "validationStringency": "",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func validateSamFile(
        configuration: GATKValidateSamFileConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        var inputs = [GATKFileArtifact(url: configuration.inputBAMURL, format: .bam, role: .input)]
        if let referenceFASTAURL = configuration.referenceFASTAURL {
            inputs.append(GATKFileArtifact(url: referenceFASTAURL, format: .fasta, role: .reference))
        }
        let outputs = configuration.outputReportURL.map {
            [GATKFileArtifact(url: $0, format: .text, role: .report)]
        } ?? []
        return GATKPipelineExecutionRequest(
            workflowName: "GATK ValidateSamFile",
            toolName: "gatk-validate-sam",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.validateSamFileCommand(configuration),
            outputDirectory: (configuration.outputReportURL ?? configuration.inputBAMURL).deletingLastPathComponent(),
            inputs: inputs,
            outputs: outputs,
            options: [
                "mode": configuration.mode.rawValue,
                "validateIndex": String(configuration.validateIndex),
                "ignoreWarnings": String(configuration.ignoreWarnings),
                "reference": configuration.referenceFASTAURL?.path ?? "",
                "outputReport": configuration.outputReportURL?.path ?? "",
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "mode": GATKValidateSamFileMode.summary.rawValue,
                "validateIndex": "true",
                "ignoreWarnings": "false",
                "reference": "",
                "outputReport": "",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func leftAlignAndTrimVariants(
        configuration: GATKLeftAlignAndTrimVariantsConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        var inputs = [
            GATKFileArtifact(url: configuration.referenceFASTAURL, format: .fasta, role: .reference),
            GATKFileArtifact(url: configuration.inputVCFURL, format: .vcf, role: .input),
        ]
        if let intervalsURL = configuration.intervalsURL {
            inputs.append(GATKFileArtifact(url: intervalsURL, role: .input))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK LeftAlignAndTrimVariants",
            toolName: "gatk-leftalign",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.leftAlignAndTrimVariantsCommand(configuration),
            outputDirectory: configuration.outputVCFURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: [GATKFileArtifact(url: configuration.outputVCFURL, format: .vcf, role: .output)],
            options: [
                "intervals": configuration.intervalsURL?.path ?? "",
                "splitMultiAllelics": String(configuration.splitMultiAllelics),
                "maxIndelLength": String(configuration.maxIndelLength),
                "maxLeadingBases": String(configuration.maxLeadingBases),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "intervals": "",
                "splitMultiAllelics": "false",
                "maxIndelLength": "200",
                "maxLeadingBases": "1000",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }

    static func collectVariantCallingMetrics(
        configuration: GATKCollectVariantCallingMetricsConfiguration,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity = GATKRuntimeIdentity(),
        packID: String? = "gatk-core",
        packVersion: String? = nil
    ) -> GATKPipelineExecutionRequest {
        var inputs = [
            GATKFileArtifact(url: configuration.inputVCFURL, format: .vcf, role: .input),
            GATKFileArtifact(url: configuration.dbSNPVCFURL, format: .vcf, role: .reference),
        ]
        if let sequenceDictionaryURL = configuration.sequenceDictionaryURL {
            inputs.append(GATKFileArtifact(url: sequenceDictionaryURL, format: .text, role: .reference))
        }
        return GATKPipelineExecutionRequest(
            workflowName: "GATK CollectVariantCallingMetrics",
            toolName: "gatk-collect-metrics",
            toolVersion: toolVersion,
            command: GATKCommandBuilder.collectVariantCallingMetricsCommand(configuration),
            outputDirectory: configuration.outputMetricsPrefixURL.deletingLastPathComponent(),
            inputs: inputs,
            outputs: collectMetricsOutputArtifacts(prefix: configuration.outputMetricsPrefixURL),
            options: [
                "sequenceDictionary": configuration.sequenceDictionaryURL?.path ?? "",
                "isGVCFInput": String(configuration.isGVCFInput),
                "extraArguments": jsonArrayString(configuration.extraArguments),
            ],
            resolvedDefaults: [
                "sequenceDictionary": "",
                "isGVCFInput": "false",
                "extraArguments": "[]",
            ],
            runtimeIdentity: runtimeIdentity,
            packID: packID,
            packVersion: packVersion
        )
    }
}

private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func jsonArrayString(_ values: [String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
          let string = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return string
}

private func collectMetricsOutputArtifacts(prefix: URL) -> [GATKFileArtifact] {
    [
        GATKFileArtifact(
            url: prefix.appendingPathExtension("variant_calling_summary_metrics"),
            format: .text,
            role: .report
        ),
        GATKFileArtifact(
            url: prefix.appendingPathExtension("variant_calling_detail_metrics"),
            format: .text,
            role: .report
        ),
    ]
}
