// GATKPipelineExecutor.swift - Execute GATK commands with final-location provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

private final class GATKDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public struct GATKCommandExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let wallTime: TimeInterval

    public init(exitCode: Int32, stdout: String, stderr: String, wallTime: TimeInterval) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.wallTime = wallTime
    }

    public var isSuccess: Bool {
        exitCode == 0
    }
}

public protocol GATKCommandRunning: Sendable {
    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult
}

public struct ProcessGATKCommandRunner: GATKCommandRunning {
    public let environment: [String: String]

    public init(environment: [String: String] = [:]) {
        self.environment = environment
    }

    public func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        try await Task.detached(priority: .userInitiated) {
            try runGATKProcess(command, environment: environment)
        }.value
    }
}

public struct ManagedGATKCommandRunner: GATKCommandRunning {
    public let condaManager: CondaManager
    public let timeout: TimeInterval

    public init(
        condaManager: CondaManager = .shared,
        timeout: TimeInterval = 24 * 60 * 60
    ) {
        self.condaManager = condaManager
        self.timeout = timeout
    }

    public func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            timeout: timeout
        )
        return GATKCommandExecutionResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            wallTime: Date().timeIntervalSince(startedAt)
        )
    }
}

private func runGATKProcess(
    _ command: GATKCommand,
    environment: [String: String]
) throws -> GATKCommandExecutionResult {
    let process = Process()
    if command.executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments
    }
    if let workingDirectory = command.workingDirectory {
        process.currentDirectoryURL = workingDirectory
    }
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let start = Date()
    try process.run()
    let stdoutBox = GATKDataBox()
    let stderrBox = GATKDataBox()
    let drainGroup = DispatchGroup()
    drainGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        drainGroup.leave()
    }

    process.waitUntilExit()
    drainGroup.wait()
    let wallTime = Date().timeIntervalSince(start)
    let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
    let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""
    return GATKCommandExecutionResult(
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr,
        wallTime: wallTime
    )
}

public struct GATKFileArtifact: Sendable, Equatable {
    public let url: URL
    public let format: FileFormat?
    public let role: FileRole

    public init(url: URL, format: FileFormat? = nil, role: FileRole) {
        self.url = url
        self.format = format
        self.role = role
    }

    public func fileRecord() -> FileRecord {
        ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
    }
}

public struct GATKRuntimeIdentity: Sendable, Equatable {
    public let condaEnvironment: String?
    public let containerImage: String?
    public let containerDigest: String?

    public init(
        condaEnvironment: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil
    ) {
        self.condaEnvironment = condaEnvironment
        self.containerImage = containerImage
        self.containerDigest = containerDigest
    }
}

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

public struct GATKPipelineExecutionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let provenanceURL: URL
}

private struct GATKExecutedCommand {
    let command: GATKCommand
    let result: GATKCommandExecutionResult
}

public enum GATKPipelineExecutionError: Error, LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, provenanceURL: URL)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let exitCode, let provenanceURL):
            return "GATK command failed with exit code \(exitCode). Provenance was written to \(provenanceURL.path)."
        }
    }
}

public struct GATKPipelineExecutor<Runner: GATKCommandRunning> {
    public typealias DateProvider = @Sendable () -> Date

    private let runner: Runner
    private let dateProvider: DateProvider
    private let fileManager: FileManager

    public init(
        runner: Runner,
        fileManager: FileManager = .default,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    public func run(_ request: GATKPipelineExecutionRequest) async throws -> GATKPipelineExecutionResult {
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let startedAt = dateProvider()
        var executedCommands: [GATKExecutedCommand] = []
        for command in request.commands {
            let commandResult = try await runner.run(command)
            executedCommands.append(GATKExecutedCommand(command: command, result: commandResult))
            guard commandResult.isSuccess else {
                let completedAt = dateProvider()
                let provenanceURL = try writeProvenance(
                    request: request,
                    executedCommands: executedCommands,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    status: .failed
                )
                throw GATKPipelineExecutionError.commandFailed(
                    exitCode: commandResult.exitCode,
                    provenanceURL: provenanceURL
                )
            }
        }
        let completedAt = dateProvider()
        let provenanceURL = try writeProvenance(
            request: request,
            executedCommands: executedCommands,
            startedAt: startedAt,
            completedAt: completedAt,
            status: .completed
        )
        return GATKPipelineExecutionResult(
            exitCode: executedCommands.last?.result.exitCode ?? 0,
            stdout: executedCommands.map(\.result.stdout).filter { !$0.isEmpty }.joined(separator: "\n"),
            stderr: executedCommands.map(\.result.stderr).filter { !$0.isEmpty }.joined(separator: "\n"),
            provenanceURL: provenanceURL
        )
    }

    private func writeProvenance(
        request: GATKPipelineExecutionRequest,
        executedCommands: [GATKExecutedCommand],
        startedAt: Date,
        completedAt: Date,
        status: RunStatus
    ) throws -> URL {
        let steps = executedCommands.map { executed in
            StepExecution(
                toolName: request.toolName,
                toolVersion: request.toolVersion,
                containerImage: request.runtimeIdentity.containerImage,
                containerDigest: request.runtimeIdentity.containerDigest,
                command: [executed.command.executable] + executed.command.arguments,
                inputs: request.inputs.map { $0.fileRecord() },
                outputs: request.outputs.map { $0.fileRecord() },
                exitCode: executed.result.exitCode,
                wallTime: executed.result.wallTime,
                stderr: executed.result.stderr.isEmpty ? nil : executed.result.stderr,
                startTime: startedAt,
                endTime: completedAt
            )
        }
        let run = WorkflowRun(
            name: request.workflowName,
            startTime: startedAt,
            endTime: completedAt,
            status: status,
            steps: steps,
            parameters: parameters(for: request)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let provenanceURL = request.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
        return provenanceURL
    }

    private func parameters(for request: GATKPipelineExecutionRequest) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "toolEnvironment": .string(request.commands.map(\.environment).uniqued().joined(separator: ",")),
            "toolExecutable": .string(request.commands.map(\.executable).uniqued().joined(separator: ",")),
            "shellCommand": .string(request.commands.map(\.shellCommand).joined(separator: " && ")),
            "shellCommands": .array(request.commands.map { .string($0.shellCommand) }),
        ]
        if let packID = request.packID {
            parameters["packID"] = .string(packID)
        }
        if let packVersion = request.packVersion {
            parameters["packVersion"] = .string(packVersion)
        }
        if let condaEnvironment = request.runtimeIdentity.condaEnvironment {
            parameters["condaEnvironment"] = .string(condaEnvironment)
        }
        if let containerImage = request.runtimeIdentity.containerImage {
            parameters["containerImage"] = .string(containerImage)
        }
        if let containerDigest = request.runtimeIdentity.containerDigest {
            parameters["containerDigest"] = .string(containerDigest)
        }
        for (key, value) in request.options {
            parameters["option.\(key)"] = .string(value)
        }
        for (key, value) in request.resolvedDefaults {
            parameters["default.\(key)"] = .string(value)
        }
        return parameters
    }
}

public extension GATKPipelineExecutor where Runner == ProcessGATKCommandRunner {
    init(
        fileManager: FileManager = .default,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.init(
            runner: ProcessGATKCommandRunner(),
            fileManager: fileManager,
            dateProvider: dateProvider
        )
    }
}

public extension GATKPipelineExecutor where Runner == ManagedGATKCommandRunner {
    init(
        fileManager: FileManager = .default,
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.init(
            runner: ManagedGATKCommandRunner(),
            fileManager: fileManager,
            dateProvider: dateProvider
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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
