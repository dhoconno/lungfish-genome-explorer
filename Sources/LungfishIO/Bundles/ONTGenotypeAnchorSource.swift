import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeAnchorSource: String, Codable, Equatable, Sendable {
    case labelToken
    case unanchored

    public var displayName: String {
        switch self {
        case .labelToken:
            return "Source Label Token"
        case .unanchored:
            return "No Source Token"
        }
    }
}
