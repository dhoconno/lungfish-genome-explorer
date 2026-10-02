import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeQCStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case ok
    case lowSupport
    case review

    public var displayName: String {
        switch self {
        case .ok:
            return "OK"
        case .lowSupport:
            return "Low Support"
        case .review:
            return "Review"
        }
    }
}
