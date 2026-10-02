import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeSupportDenominator: String, Codable, CaseIterable, Equatable, Sendable {
    case viewedLocus
    case sampleRetained

    public var displayName: String {
        switch self {
        case .viewedLocus:
            return "Source Locus"
        case .sampleRetained:
            return "Sample Retained"
        }
    }
}
