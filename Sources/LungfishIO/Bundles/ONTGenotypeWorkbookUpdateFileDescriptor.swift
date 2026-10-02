import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeWorkbookUpdateFileDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(path: String, sizeBytes: Int64, sha256: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}
