import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct GenotypeAnnotationSidecarSnapshot: Equatable, Sendable {
    public let sidecar: GenotypeAnnotationSidecar
    public let revision: GenotypeAnnotationSidecarRevision
    public let data: Data?

    public init(
        sidecar: GenotypeAnnotationSidecar,
        revision: GenotypeAnnotationSidecarRevision,
        data: Data?
    ) {
        self.sidecar = sidecar
        self.revision = revision
        self.data = data
    }
}
