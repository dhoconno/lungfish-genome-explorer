import Foundation
import LungfishCore
import LungfishIO

public enum ViralVariantCaller: String, CaseIterable, Sendable, Codable {
    case lofreq
    case ivar
    case medaka
    case bcftools

    public var displayName: String {
        switch self {
        case .lofreq:
            return "LoFreq"
        case .ivar:
            return "iVar"
        case .medaka:
            return "Medaka"
        case .bcftools:
            return "bcftools"
        }
    }

    public var callSemantics: String {
        "viral_frequency"
    }
}

public struct BundleVariantCallingRequest: Sendable, Equatable {
    public let bundleURL: URL
    public let alignmentTrackID: String
    public let caller: ViralVariantCaller
    public let outputTrackName: String
    public let threads: Int
    public let minimumAlleleFrequency: Double?
    public let minimumDepth: Int?
    public let ivarPrimerTrimConfirmed: Bool
    public let medakaModel: String?
    public let advancedArguments: [String]
    public let ivarConsensusAF: Double
    public let ivarMergeAFThreshold: Double
    public let ivarBadQualityThreshold: Int
    public let ivarIgnoreStrandBias: Bool

    public init(
        bundleURL: URL,
        alignmentTrackID: String,
        caller: ViralVariantCaller,
        outputTrackName: String,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minimumAlleleFrequency: Double? = nil,
        minimumDepth: Int? = nil,
        ivarPrimerTrimConfirmed: Bool = false,
        medakaModel: String? = nil,
        advancedArguments: [String] = [],
        ivarConsensusAF: Double = 0.75,
        ivarMergeAFThreshold: Double = 0.25,
        ivarBadQualityThreshold: Int = 20,
        ivarIgnoreStrandBias: Bool = true
    ) {
        self.bundleURL = bundleURL
        self.alignmentTrackID = alignmentTrackID
        self.caller = caller
        self.outputTrackName = outputTrackName
        self.threads = threads
        self.minimumAlleleFrequency = minimumAlleleFrequency
        self.minimumDepth = minimumDepth
        self.ivarPrimerTrimConfirmed = ivarPrimerTrimConfirmed
        self.medakaModel = medakaModel
        self.advancedArguments = advancedArguments
        self.ivarConsensusAF = ivarConsensusAF
        self.ivarMergeAFThreshold = ivarMergeAFThreshold
        self.ivarBadQualityThreshold = ivarBadQualityThreshold
        self.ivarIgnoreStrandBias = ivarIgnoreStrandBias
    }
}

public struct VariantSQLiteImportRequest: Sendable, Equatable {
    public let normalizedVCFURL: URL
    public let outputDatabaseURL: URL
    public let sourceFile: String?
    public let importProfile: VCFImportProfile
    public let importSemantics: VCFImportSemantics
    public let materializeVariantInfo: Bool

    public init(
        normalizedVCFURL: URL,
        outputDatabaseURL: URL,
        sourceFile: String? = nil,
        importProfile: VCFImportProfile = .ultraLowMemory,
        importSemantics: VCFImportSemantics = .viralFrequency,
        materializeVariantInfo: Bool = true
    ) {
        self.normalizedVCFURL = normalizedVCFURL
        self.outputDatabaseURL = outputDatabaseURL
        self.sourceFile = sourceFile
        self.importProfile = importProfile
        self.importSemantics = importSemantics
        self.materializeVariantInfo = materializeVariantInfo
    }
}

public struct VariantSQLiteImportResult: Sendable, Equatable {
    public let databaseURL: URL
    public let variantCount: Int
    public let didResumeIndexBuild: Bool
    public let didResumeMaterialization: Bool

    public init(
        databaseURL: URL,
        variantCount: Int,
        didResumeIndexBuild: Bool,
        didResumeMaterialization: Bool
    ) {
        self.databaseURL = databaseURL
        self.variantCount = variantCount
        self.didResumeIndexBuild = didResumeIndexBuild
        self.didResumeMaterialization = didResumeMaterialization
    }
}

public struct VariantCallingProvenanceStep: Sendable, Codable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let command: [String]
    public let inputs: [FileRecord]
    public let outputs: [FileRecord]
    public let exitCode: Int32?
    public let wallTime: TimeInterval?
    public let stderr: String?
    public let startedAt: Date
    public let completedAt: Date?

    public init(
        toolName: String,
        toolVersion: String,
        command: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        exitCode: Int32?,
        wallTime: TimeInterval?,
        stderr: String?,
        startedAt: Date,
        completedAt: Date?
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.command = command
        self.inputs = inputs
        self.outputs = outputs
        self.exitCode = exitCode
        self.wallTime = wallTime
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public func stepExecution(dependsOn: [UUID] = []) -> StepExecution {
        StepExecution(
            toolName: toolName,
            toolVersion: toolVersion,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            stderr: stderr,
            dependsOn: dependsOn,
            startTime: startedAt,
            endTime: completedAt
        )
    }
}

public struct VariantCallingWorkflowProvenance: Sendable, Codable, Equatable {
    public let workflowName: String
    public let workflowVersion: String
    public let command: [String]
    public let startedAt: Date
    public let completedAt: Date
    public let parameters: [String: String]
    public let steps: [VariantCallingProvenanceStep]

    public init(
        workflowName: String,
        workflowVersion: String,
        command: [String],
        startedAt: Date,
        completedAt: Date,
        parameters: [String: String],
        steps: [VariantCallingProvenanceStep]
    ) {
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.command = command
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.parameters = parameters
        self.steps = steps
    }
}

public struct BundleVariantTrackAttachmentRequest: Sendable {
    public let bundleURL: URL
    public let alignmentTrackID: String
    public let caller: ViralVariantCaller
    public let outputTrackID: String
    public let outputTrackName: String
    public let stagedVCFGZURL: URL
    public let stagedTabixURL: URL
    public let stagedDatabaseURL: URL
    public let variantCount: Int?
    public let variantCallerVersion: String
    public let variantCallerParametersJSON: String
    public let variantCallerCommandLine: String
    public let referenceStagedFASTASHA256: String
    public let workflowProvenance: VariantCallingWorkflowProvenance?

    public init(
        bundleURL: URL,
        alignmentTrackID: String,
        caller: ViralVariantCaller,
        outputTrackID: String,
        outputTrackName: String,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        stagedDatabaseURL: URL,
        variantCount: Int?,
        variantCallerVersion: String,
        variantCallerParametersJSON: String,
        variantCallerCommandLine: String = "",
        referenceStagedFASTASHA256: String,
        workflowProvenance: VariantCallingWorkflowProvenance? = nil
    ) {
        self.bundleURL = bundleURL
        self.alignmentTrackID = alignmentTrackID
        self.caller = caller
        self.outputTrackID = outputTrackID
        self.outputTrackName = outputTrackName
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.stagedDatabaseURL = stagedDatabaseURL
        self.variantCount = variantCount
        self.variantCallerVersion = variantCallerVersion
        self.variantCallerParametersJSON = variantCallerParametersJSON
        self.variantCallerCommandLine = variantCallerCommandLine
        self.referenceStagedFASTASHA256 = referenceStagedFASTASHA256
        self.workflowProvenance = workflowProvenance
    }
}

public struct BundleVariantTrackAttachmentResult: Sendable, Equatable {
    public let trackInfo: VariantTrackInfo
    public let finalVCFGZURL: URL
    public let finalTabixURL: URL
    public let finalDatabaseURL: URL
    public let provenanceURL: URL?

    public init(
        trackInfo: VariantTrackInfo,
        finalVCFGZURL: URL,
        finalTabixURL: URL,
        finalDatabaseURL: URL,
        provenanceURL: URL? = nil
    ) {
        self.trackInfo = trackInfo
        self.finalVCFGZURL = finalVCFGZURL
        self.finalTabixURL = finalTabixURL
        self.finalDatabaseURL = finalDatabaseURL
        self.provenanceURL = provenanceURL
    }
}
