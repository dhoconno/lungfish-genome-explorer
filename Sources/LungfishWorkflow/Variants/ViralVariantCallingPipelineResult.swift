import Foundation
import LungfishCore
import LungfishIO
import os.log

public struct ViralVariantCallingPipelineResult: Sendable, Equatable {
    public let normalizedVCFURL: URL
    public let stagedVCFGZURL: URL
    public let stagedTabixURL: URL
    public let referenceFASTAURL: URL
    public let referenceFASTASHA256: String
    public let callerVersion: String
    public let callerParametersJSON: String
    public let commandLine: String
    public let provenanceSteps: [VariantCallingProvenanceStep]

    public init(
        normalizedVCFURL: URL,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        referenceFASTAURL: URL,
        referenceFASTASHA256: String,
        callerVersion: String,
        callerParametersJSON: String,
        commandLine: String = "",
        provenanceSteps: [VariantCallingProvenanceStep] = []
    ) {
        self.normalizedVCFURL = normalizedVCFURL
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.referenceFASTAURL = referenceFASTAURL
        self.referenceFASTASHA256 = referenceFASTASHA256
        self.callerVersion = callerVersion
        self.callerParametersJSON = callerParametersJSON
        self.commandLine = commandLine
        self.provenanceSteps = provenanceSteps
    }
}
