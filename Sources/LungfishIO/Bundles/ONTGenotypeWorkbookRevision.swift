import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeWorkbookRevision: Codable, Equatable, Sendable {
    public let id: String
    public let role: ONTGenotypeWorkbookRevisionRole
    public let path: String
    public let label: String
    public let sourceFilename: String?
    public let createdAt: String
    public let user: String?
    public let predecessorID: String?
    public let predecessorPath: String?
    public let sha256: String
    public let sizeBytes: Int64
    public let provenancePath: String?

    public init(
        id: String,
        role: ONTGenotypeWorkbookRevisionRole,
        path: String,
        label: String,
        sourceFilename: String? = nil,
        createdAt: String,
        user: String? = nil,
        predecessorID: String? = nil,
        predecessorPath: String? = nil,
        sha256: String,
        sizeBytes: Int64,
        provenancePath: String? = nil
    ) {
        self.id = id
        self.role = role
        self.path = path
        self.label = label
        self.sourceFilename = sourceFilename
        self.createdAt = createdAt
        self.user = user
        self.predecessorID = predecessorID
        self.predecessorPath = predecessorPath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.provenancePath = provenancePath
    }
}
