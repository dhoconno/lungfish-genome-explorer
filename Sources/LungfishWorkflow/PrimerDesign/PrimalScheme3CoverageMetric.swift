import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum PrimalScheme3CoverageMetric: String, Codable, CaseIterable, Sendable {
    case fullSpan = "full-span"
    case primerTrimmed = "primer-trimmed"
    case observedAllelePrimerTrimmed = "observed-allele-primer-trimmed"
}
