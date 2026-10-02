import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeHaplotypeAnalysisRevision: Codable, Equatable, Sendable {
    public let id: String
    public let method: ONTGenotypeHaplotypeAnalysisMethod
    public let path: String
    public let predecessorID: String?
    public let predecessorPath: String?
    public let createdAt: String
    public let reviewState: ONTGenotypeHaplotypeAnalysisReviewState
    public let sha256: String
    public let sizeBytes: Int64
    public let provenancePath: String
    public let provider: String?
    public let model: String?
    public let promptTemplateID: String?
    public let promptTemplateVersion: String?
    public let promptHash: String?
    public let promptSnapshotPath: String?
    public let evidenceSnapshotPath: String?
    public let validationReportPath: String?

    public init(
        id: String,
        method: ONTGenotypeHaplotypeAnalysisMethod,
        path: String,
        predecessorID: String? = nil,
        predecessorPath: String? = nil,
        createdAt: String,
        reviewState: ONTGenotypeHaplotypeAnalysisReviewState,
        sha256: String,
        sizeBytes: Int64,
        provenancePath: String,
        provider: String? = nil,
        model: String? = nil,
        promptTemplateID: String? = nil,
        promptTemplateVersion: String? = nil,
        promptHash: String? = nil,
        promptSnapshotPath: String? = nil,
        evidenceSnapshotPath: String? = nil,
        validationReportPath: String? = nil
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.predecessorID = predecessorID
        self.predecessorPath = predecessorPath
        self.createdAt = createdAt
        self.reviewState = reviewState
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.provenancePath = provenancePath
        self.provider = provider
        self.model = model
        self.promptTemplateID = promptTemplateID
        self.promptTemplateVersion = promptTemplateVersion
        self.promptHash = promptHash
        self.promptSnapshotPath = promptSnapshotPath
        self.evidenceSnapshotPath = evidenceSnapshotPath
        self.validationReportPath = validationReportPath
    }
}
