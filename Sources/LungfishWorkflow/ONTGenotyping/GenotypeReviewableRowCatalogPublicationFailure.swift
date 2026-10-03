import Darwin
import CryptoKit
import Foundation
import LungfishIO

public struct GenotypeReviewableRowCatalogPublicationFailure:
    Error,
    LocalizedError,
    @unchecked Sendable
{
    public let message: String
    public let provenance: ProvenanceEnvelope
    public let underlyingError: Error

    public init(
        message: String,
        provenance: ProvenanceEnvelope,
        underlyingError: Error
    ) {
        self.message = message
        self.provenance = provenance
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? { message }
}
