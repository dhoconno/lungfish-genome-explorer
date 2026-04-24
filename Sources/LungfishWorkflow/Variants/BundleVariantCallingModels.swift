import Foundation
import LungfishCore
import LungfishIO

public enum ViralVariantCaller: String, CaseIterable, Sendable, Codable {
    case lofreq
    case ivar
    case medaka

    public var displayName: String {
        switch self {
        case .lofreq:
            return "LoFreq"
        case .ivar:
            return "iVar"
        case .medaka:
            return "Medaka"
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
        advancedArguments: [String] = []
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
        referenceStagedFASTASHA256: String
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
    }
}

public struct BundleVariantTrackAttachmentResult: Sendable, Equatable {
    public let trackInfo: VariantTrackInfo
    public let finalVCFGZURL: URL
    public let finalTabixURL: URL
    public let finalDatabaseURL: URL

    public init(
        trackInfo: VariantTrackInfo,
        finalVCFGZURL: URL,
        finalTabixURL: URL,
        finalDatabaseURL: URL
    ) {
        self.trackInfo = trackInfo
        self.finalVCFGZURL = finalVCFGZURL
        self.finalTabixURL = finalTabixURL
        self.finalDatabaseURL = finalDatabaseURL
    }
}
