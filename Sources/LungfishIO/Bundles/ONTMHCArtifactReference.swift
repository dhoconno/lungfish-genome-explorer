import Foundation

public struct ONTMHCArtifactReference: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let sizeBytes: Int64

    public init(path: String, sha256: String, sizeBytes: Int64) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case sizeBytes = "size_bytes"
    }
}
