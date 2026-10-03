import Darwin
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import SQLite3

public enum MappingViewerBundlePublicationError: Error, LocalizedError {
    case missingCanonicalProvenance(URL)
    case missingViewerBundle(URL)
    case invalidViewerPayloadPath(String)
    case missingViewerPayload(URL)
    case invalidCandidateLocation(URL, URL)
    case unsafePublicationRoot(String)
    case atomicPublicationFailed(URL, URL, String)
    case concurrentSidecarChanges([String])
    case publicationOwnershipConflict(String, String?)
    case rollbackFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .missingCanonicalProvenance(let url):
            return "Canonical mapping provenance is missing at \(url.path)."
        case .missingViewerBundle(let url):
            return "The prepared mapping viewer bundle is missing at \(url.path)."
        case .invalidViewerPayloadPath(let path):
            return "The mapping viewer bundle declares an unsafe payload path: \(path)."
        case .missingViewerPayload(let url):
            return "The mapping viewer bundle payload is missing at \(url.path)."
        case .invalidCandidateLocation(let candidate, let final):
            return "The mapping viewer candidate \(candidate.path) must be adjacent to its final bundle \(final.path)."
        case .unsafePublicationRoot(let path):
            return "The mapping viewer publication root is not a no-follow directory: \(path)."
        case .atomicPublicationFailed(let candidate, let final, let detail):
            return "Could not atomically publish \(candidate.lastPathComponent) as \(final.lastPathComponent): \(detail)"
        case .concurrentSidecarChanges(let paths):
            return "Mapping viewer rollback preserved newer sidecar generations at: \(paths.joined(separator: ", "))."
        case .publicationOwnershipConflict(let path, let preservedPath):
            let suffix = preservedPath.map { " The displaced original was preserved at \($0)." } ?? ""
            return "The published mapping viewer root was replaced by another filesystem generation at \(path).\(suffix)"
        case .rollbackFailed(let url, let detail):
            return "Could not restore \(url.lastPathComponent) after mapping viewer publication failed: \(detail)"
        }
    }
}
