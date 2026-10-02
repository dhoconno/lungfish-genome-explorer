import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public enum PhylogeneticTreeBundleError: Error, LocalizedError, Sendable, Equatable {
    case sourceMissing(String)
    case destinationAlreadyExists(String)
    case unsupportedFormat(String)
    case parseFailed(String)
    case missingBundleFile(String)
    case sqliteIndexFailed(String)
    case nodeNotFound(String)
    case ambiguousNodeLabel(String)
    case cannotRootOnRootNode(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "Tree source file does not exist: \(path)"
        case .destinationAlreadyExists(let path):
            return "Tree bundle destination already exists: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported phylogenetic tree format: \(format)"
        case .parseFailed(let message):
            return "Could not parse phylogenetic tree: \(message)"
        case .missingBundleFile(let path):
            return "Tree bundle is missing required file: \(path)"
        case .sqliteIndexFailed(let message):
            return "Could not write tree index: \(message)"
        case .nodeNotFound(let selector):
            return "Tree node not found: \(selector)"
        case .ambiguousNodeLabel(let label):
            return "Tree node label is ambiguous: \(label)"
        case .cannotRootOnRootNode(let label):
            return "Cannot root on the branch above \(label): it is already the root and has no branch above it. Select one of its child clades instead."
        }
    }
}
