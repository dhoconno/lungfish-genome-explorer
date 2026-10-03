import Darwin
import CryptoKit
import Foundation
import LungfishIO

public struct GenotypeReviewableRowCatalogPublication: Sendable {
    public let document: GenotypeReviewableRowCatalog
    public let artifact: ONTMHCArtifactReference
    public let outputURL: URL
    public let provenance: ProvenanceEnvelope

    public init(
        document: GenotypeReviewableRowCatalog,
        artifact: ONTMHCArtifactReference,
        outputURL: URL,
        provenance: ProvenanceEnvelope
    ) {
        self.document = document
        self.artifact = artifact
        self.outputURL = outputURL
        self.provenance = provenance
    }

}
