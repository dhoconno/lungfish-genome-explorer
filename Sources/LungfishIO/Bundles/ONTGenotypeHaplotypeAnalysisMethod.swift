import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeHaplotypeAnalysisMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case deterministic
    case aiDiscovery
    case aiRefinement
}
