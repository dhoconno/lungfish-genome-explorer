import Foundation
import LungfishCore
import LungfishIO

public struct AIHaplotypingRunFailure: Error, LocalizedError, Codable, Equatable, Sendable {
    public let stage: AIHaplotypingRunFailureStage
    public let sanitizedErrorCategory: String
    public let message: String
    public let attemptMetadata: AIProviderAttemptMetadata?
    public let validationReport: AIHaplotypingValidationReport?

    public init(
        stage: AIHaplotypingRunFailureStage,
        sanitizedErrorCategory: String,
        message: String,
        attemptMetadata: AIProviderAttemptMetadata? = nil,
        validationReport: AIHaplotypingValidationReport? = nil
    ) {
        self.stage = stage
        self.sanitizedErrorCategory = sanitizedErrorCategory
        self.message = message
        self.attemptMetadata = attemptMetadata
        self.validationReport = validationReport
    }

    public var errorDescription: String? { message }
}
