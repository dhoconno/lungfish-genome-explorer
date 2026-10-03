import CryptoKit
import Darwin
import Foundation
import LungfishIO

public enum PrimalScheme3SelectionAlgorithm: String, Codable, CaseIterable, Sendable {
    case legacy, coverage
    case alleleCoverage = "allele-coverage"
}
