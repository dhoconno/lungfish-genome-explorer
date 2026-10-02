import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum GenotypeResultWorkflowMode: String, Codable, CaseIterable, Equatable, Sendable {
    case genotypeOnly
    case haplotyped
}
