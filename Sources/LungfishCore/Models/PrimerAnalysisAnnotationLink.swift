import Foundation

/// Durable references from a displayed annotation to its saved analysis result.
///
/// These references survive serialization paths that recreate annotation UUIDs.
/// Resolving the referenced bundle and verifying source checksums or coordinates
/// remain the responsibility of the consumer.
public struct PrimerAnalysisAnnotationLink: Codable, Sendable, Equatable {
    public let analysisID: UUID
    public let resultID: UUID
    public let inputID: UUID

    public init(analysisID: UUID, resultID: UUID, inputID: UUID) {
        self.analysisID = analysisID
        self.resultID = resultID
        self.inputID = inputID
    }

    public enum LinkError: Error, LocalizedError, Sendable, Equatable {
        case invalidQualifier(String)
        case unsupportedVersion(String)
        case conflictingLink

        public var errorDescription: String? {
            switch self {
            case .invalidQualifier(let key):
                return "The primer analysis annotation link has a missing or invalid \(key) qualifier."
            case .unsupportedVersion(let version):
                return "Primer analysis annotation link version \(version) is not supported."
            case .conflictingLink:
                return "This annotation is already linked to a different primer analysis result."
            }
        }
    }

    private enum Key {
        static let version = "lungfish_primer_link_version"
        static let analysis = "lungfish_primer_analysis_id"
        static let result = "lungfish_primer_result_id"
        static let input = "lungfish_primer_input_id"
        static let all = [version, analysis, result, input]
    }

    /// Returns nil only when the annotation has no recognized link qualifiers.
    /// A partial or malformed link is an error rather than an unlinked feature.
    public static func read(from annotation: SequenceAnnotation) throws -> Self? {
        guard Key.all.contains(where: { annotation.qualifiers[$0] != nil }) else { return nil }
        let version = try scalar(Key.version, in: annotation)
        guard version == "1" else { throw LinkError.unsupportedVersion(version) }
        return try Self(
            analysisID: identifier(Key.analysis, in: annotation),
            resultID: identifier(Key.result, in: annotation),
            inputID: identifier(Key.input, in: annotation)
        )
    }

    /// Adds the link to a copy, preserving all other feature metadata.
    /// Reattachment is idempotent, and a different existing link is never replaced.
    public func attaching(to annotation: SequenceAnnotation) throws -> SequenceAnnotation {
        if let existing = try Self.read(from: annotation) {
            guard existing == self else { throw LinkError.conflictingLink }
            return annotation
        }
        var linked = annotation
        linked.qualifiers[Key.version] = AnnotationQualifier("1")
        linked.qualifiers[Key.analysis] = AnnotationQualifier(analysisID.uuidString)
        linked.qualifiers[Key.result] = AnnotationQualifier(resultID.uuidString)
        linked.qualifiers[Key.input] = AnnotationQualifier(inputID.uuidString)
        return linked
    }

    private static func scalar(_ key: String, in annotation: SequenceAnnotation) throws -> String {
        let values = annotation.qualifierValues(key)
        guard values.count == 1, let value = values.first, !value.isEmpty else {
            throw LinkError.invalidQualifier(key)
        }
        return value
    }

    private static func identifier(_ key: String, in annotation: SequenceAnnotation) throws -> UUID {
        let value = try scalar(key, in: annotation)
        guard let id = UUID(uuidString: value) else { throw LinkError.invalidQualifier(key) }
        return id
    }
}
