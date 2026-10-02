import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeIntegrityWarning: Codable, Equatable, Sendable {
    public let code: ONTGenotypeIntegrityWarningCode
    public let detail: String
    public let path: String?

    public init(code: ONTGenotypeIntegrityWarningCode, detail: String, path: String? = nil) {
        self.code = code
        self.detail = detail
        self.path = path
    }
}
