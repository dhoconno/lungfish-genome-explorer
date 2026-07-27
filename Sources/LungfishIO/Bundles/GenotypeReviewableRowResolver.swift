import Foundation

public struct GenotypeReviewableRowResolver: Sendable {
    private struct ReferenceKey: Hashable, Sendable {
        let locus: String
        let displayName: String
    }

    private struct CandidateKey: Hashable, Sendable {
        let locus: String
        let displayName: String
        let stableID: String
    }

    public enum ResolutionError: Error, LocalizedError, Equatable, Sendable {
        case targetIsNotCell
        case invalidTargetIdentity
        case sampleOutsideRoster(String)
        case noAuthoritativeMatch
        case ambiguousAuthoritativeMatch
        case sampleHasEvidence(sample: String, support: Int)
        case cohortHasEvidence(samples: [String])

        public var errorDescription: String? {
            switch self {
            case .targetIsNotCell:
                return "A false-negative review requires an individual genotype matrix cell."
            case .invalidTargetIdentity:
                return "The false-negative target has an invalid semantic identity."
            case let .sampleOutsideRoster(sample):
                return "Sample \(sample) is not in the authoritative genotype roster."
            case .noAuthoritativeMatch:
                return "No reviewable-row catalog record exactly matches the false-negative target."
            case .ambiguousAuthoritativeMatch:
                return "More than one reviewable-row catalog record matches the false-negative target."
            case let .sampleHasEvidence(sample, support):
                return "Sample \(sample) has \(support) supporting reads and cannot be marked false negative."
            case let .cohortHasEvidence(samples):
                return "An annotation-only cohort-zero row cannot be created because evidence exists for: \(samples.joined(separator: ", "))."
            }
        }
    }

    public let catalog: GenotypeReviewableRowCatalog
    private let referenceRows: [ReferenceKey: [GenotypeReviewableRowCatalog.Row]]
    private let candidateRows: [CandidateKey: [GenotypeReviewableRowCatalog.Row]]
    private let roster: Set<String>

    public init(catalog: GenotypeReviewableRowCatalog) throws {
        self.catalog = try catalog.validated()
        self.roster = Set(catalog.samples)
        self.referenceRows = Dictionary(
            grouping: catalog.rows.filter { $0.kind == .reference },
            by: { ReferenceKey(locus: $0.locus, displayName: $0.displayName) }
        )
        self.candidateRows = Dictionary(
            grouping: catalog.rows.filter { $0.kind != .reference },
            by: {
                CandidateKey(
                    locus: $0.locus,
                    displayName: $0.displayName,
                    stableID: $0.stableID!
                )
            }
        )
    }

    public func resolveFalseNegative(
        target: GenotypeAnnotationSidecar.MatrixTarget,
        requiresCohortZero: Bool
    ) throws -> GenotypeReviewableRowCatalog.Row {
        guard case let .cell(rawLocus, genotype, sample, stableID) = target else {
            throw ResolutionError.targetIsNotCell
        }
        guard Self.isCanonicalNonemptyIdentity(rawLocus),
              Self.isCanonicalNonemptyIdentity(genotype),
              Self.isCanonicalNonemptyIdentity(sample) else {
            throw ResolutionError.invalidTargetIdentity
        }
        guard roster.contains(sample) else {
            throw ResolutionError.sampleOutsideRoster(sample)
        }
        let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(rawLocus)
        guard locus != "Unknown" else {
            throw ResolutionError.invalidTargetIdentity
        }

        let matches: [GenotypeReviewableRowCatalog.Row]
        if let stableID {
            guard Self.isCanonicalNonemptyIdentity(stableID) else {
                throw ResolutionError.invalidTargetIdentity
            }
            matches = candidateRows[
                CandidateKey(locus: locus, displayName: genotype, stableID: stableID)
            ] ?? []
        } else {
            matches = referenceRows[
                ReferenceKey(locus: locus, displayName: genotype)
            ] ?? []
        }
        guard !matches.isEmpty else {
            throw ResolutionError.noAuthoritativeMatch
        }
        guard matches.count == 1, let row = matches.first else {
            throw ResolutionError.ambiguousAuthoritativeMatch
        }

        let selectedSupport = row.supportBySample[sample]!
        guard selectedSupport == 0 else {
            throw ResolutionError.sampleHasEvidence(sample: sample, support: selectedSupport)
        }
        if requiresCohortZero {
            let supportedSamples = catalog.samples.filter { row.supportBySample[$0]! != 0 }
            guard supportedSamples.isEmpty else {
                throw ResolutionError.cohortHasEvidence(samples: supportedSamples)
            }
        }
        return row
    }

    private static func isCanonicalNonemptyIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value
    }
}
