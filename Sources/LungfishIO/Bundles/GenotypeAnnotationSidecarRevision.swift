import Foundation

public enum GenotypeAnnotationSidecarRevision: Equatable, Sendable {
    case absent
    case sha256(String)
}

public enum GenotypeAnnotationSidecarPublicationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case staleRevision(
        expected: GenotypeAnnotationSidecarRevision,
        actual: GenotypeAnnotationSidecarRevision
    )
    case mismatchedPublicationLock(expectedPath: String, actualPath: String)

    public var errorDescription: String? {
        switch self {
        case .staleRevision(let expected, let actual):
            return "The genotype annotation sidecar changed before publication (expected \(expected.description), found \(actual.description))."
        case .mismatchedPublicationLock(let expectedPath, let actualPath):
            return "The genotype annotation publication lock belongs to \(actualPath), not \(expectedPath)."
        }
    }
}

private extension GenotypeAnnotationSidecarRevision {
    var description: String {
        switch self {
        case .absent: "no sidecar"
        case .sha256(let digest): "SHA-256 \(digest)"
        }
    }
}
