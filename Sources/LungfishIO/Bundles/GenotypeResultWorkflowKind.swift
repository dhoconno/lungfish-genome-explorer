import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum GenotypeResultWorkflowKind: String, Codable, CaseIterable, Equatable, Sendable {
    case fullLengthONTMHCGenotype = "full-length-ont-mhc-genotype"
    case miSeqAmpliconMHCGenotype = "miseq-amplicon-mhc-genotype"
}
