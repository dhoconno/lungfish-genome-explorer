import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingChunkOutput: Codable, Equatable, Sendable {
    public let chunkID: String
    public let registryDigest: String
    public let inputSnapshotDigest: String
    public let promptMetadata: AIHaplotypingPromptMetadata
    public let payloadDigest: String
    public let validationReport: AIHaplotypingValidationReport
    public let providerAttempt: AIProviderAttemptMetadata

    public init(
        chunkID: String,
        registryDigest: String,
        inputSnapshotDigest: String,
        promptMetadata: AIHaplotypingPromptMetadata,
        payloadDigest: String,
        validationReport: AIHaplotypingValidationReport,
        providerAttempt: AIProviderAttemptMetadata
    ) {
        self.chunkID = chunkID
        self.registryDigest = registryDigest
        self.inputSnapshotDigest = inputSnapshotDigest
        self.promptMetadata = promptMetadata
        self.payloadDigest = payloadDigest
        self.validationReport = validationReport
        self.providerAttempt = providerAttempt
    }
}
