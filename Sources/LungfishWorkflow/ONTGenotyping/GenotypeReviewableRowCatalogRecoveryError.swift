import Darwin
import CryptoKit
import Foundation
import LungfishIO

public struct GenotypeReviewableRowCatalogRecoveryError:
    Error,
    LocalizedError,
    Sendable
{
    public enum State: String, Equatable, Sendable {
        case rollbackFailed
        case priorGenerationRemovalDurabilityUncertain
    }

    public let state: State
    public let primaryErrorDescription: String
    public let rollbackErrorDescription: String
    public let canonicalOutputPath: String
    public let recoveryPaths: [String]

    public init(
        state: State = .rollbackFailed,
        primaryErrorDescription: String,
        rollbackErrorDescription: String,
        canonicalOutputPath: String,
        recoveryPaths: [String]
    ) {
        self.state = state
        self.primaryErrorDescription = primaryErrorDescription
        self.rollbackErrorDescription = rollbackErrorDescription
        self.canonicalOutputPath = canonicalOutputPath
        self.recoveryPaths = recoveryPaths
    }

    public var errorDescription: String? {
        let stateDescription = state
            == .priorGenerationRemovalDurabilityUncertain
            ? "Prior-generation removal durability is uncertain."
            : "Rollback failed."
        return """
        \(primaryErrorDescription) \(stateDescription) \(rollbackErrorDescription) \
        Canonical output: \(canonicalOutputPath). Recoverable generations: \
        \(recoveryPaths.joined(separator: ", ")).
        """
    }
}
