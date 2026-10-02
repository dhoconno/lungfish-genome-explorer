import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeReferenceRecordStoreError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat(String)
    case unsupportedSchemaVersion(Int)
    case missingFile(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case recordCountMismatch(expected: Int, actual: Int)
    case fieldCountMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value): return "Unsupported genotype reference record-store format: \(value)"
        case .unsupportedSchemaVersion(let value): return "Unsupported genotype reference record-store schema version: \(value)"
        case .missingFile(let path): return "Missing genotype reference record store: \(path)"
        case .sizeMismatch(let expected, let actual): return "Genotype reference record-store size mismatch (expected \(expected), found \(actual))"
        case .checksumMismatch(let expected, let actual): return "Genotype reference record-store checksum mismatch (expected \(expected), found \(actual))"
        case .recordCountMismatch(let expected, let actual): return "Genotype reference record count mismatch (expected \(expected), found \(actual))"
        case .fieldCountMismatch(let expected, let actual): return "Genotype reference field count mismatch (expected \(expected), found \(actual))"
        }
    }
}
