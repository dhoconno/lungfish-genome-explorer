import Foundation
import LungfishIO

public struct GenotypeMatrixEvidenceIndex: Equatable, Sendable {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget

    public struct Entry: Equatable, Sendable {
        public let target: Target
        public let passedUniqueReads: Int

        public init(target: Target, passedUniqueReads: Int) {
            self.target = target
            self.passedUniqueReads = passedUniqueReads
        }
    }

    private let passedUniqueReadsByTarget: [Target: Int]

    public init(_ passedUniqueReadsByTarget: [Target: Int] = [:]) {
        self.passedUniqueReadsByTarget = passedUniqueReadsByTarget.reduce(into: [:]) { result, entry in
            guard case .cell = entry.key else { return }
            result[entry.key] = entry.value
        }
    }

    public init(entries: [Entry]) {
        self.init(Dictionary(entries.map { ($0.target, $0.passedUniqueReads) }, uniquingKeysWith: { _, latest in latest }))
    }

    public func passedUniqueReads(for target: Target) -> Int? {
        passedUniqueReadsByTarget[target]
    }

    public func isSupported(_ target: Target) -> Bool {
        (passedUniqueReads(for: target) ?? 0) > 0
    }
}

public enum GenotypeMatrixSelectionShape: Equatable, Sendable {
    case none
    case cells
    case rows
    case columns
    case mixed
}

public struct GenotypeMatrixSupportSummary: Equatable, Sendable {
    public let supportedCount: Int
    public let unsupportedCount: Int
    public let unknownCount: Int

    public init(supportedCount: Int, unsupportedCount: Int, unknownCount: Int) {
        self.supportedCount = supportedCount
        self.unsupportedCount = unsupportedCount
        self.unknownCount = unknownCount
    }

    public var selectedCount: Int {
        supportedCount + unsupportedCount + unknownCount
    }
}

public enum GenotypeMatrixValueState<Value: Equatable & Sendable>: Equatable, Sendable {
    case none
    case uniform(Value)
    case mixed
}

public enum GenotypeMatrixCommandAvailability: Equatable, Sendable {
    case enabled
    case disabled(reason: String)

    public var isEnabled: Bool {
        self == .enabled
    }

    public var disabledReason: String? {
        guard case let .disabled(reason) = self else { return nil }
        return reason
    }
}

public struct GenotypeMatrixReviewCapabilityState: Equatable, Sendable {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    public typealias Comment = GenotypeAnnotationSidecar.MatrixComment

    public let selectionShape: GenotypeMatrixSelectionShape
    public let selectedCellCount: Int
    public let support: GenotypeMatrixSupportSummary
    public let reviewState: GenotypeMatrixValueState<GenotypeAnnotationSidecar.MatrixReviewDisposition>
    public let commentState: GenotypeMatrixValueState<String>
    /// Resolved current comments already loaded in the controller cache for the
    /// exact selection and its applicable row/column scopes.
    public let commentsByTarget: [Target: Comment]
    public let isWritable: Bool
    public let falsePositive: GenotypeMatrixCommandAvailability
    public let falseNegative: GenotypeMatrixCommandAvailability
    public let clearReview: GenotypeMatrixCommandAvailability
    public let upsertComment: GenotypeMatrixCommandAvailability
    public let removeComments: GenotypeMatrixCommandAvailability

    public var allCommands: [GenotypeMatrixCommandAvailability] {
        [falsePositive, falseNegative, clearReview, upsertComment, removeComments]
    }

    /// Returns the shared mutation decision for removing comments from an
    /// inspector scope. Scoped cards can address applicable row and column
    /// targets in addition to the exact selected targets, so they must ask the
    /// capability snapshot instead of reimplementing the writable/comment gate.
    public func removeCommentsAvailability(
        for targets: [Target]
    ) -> GenotypeMatrixCommandAvailability {
        GenotypeMatrixReviewCapability.commentRemovalAvailability(
            mutationGate: upsertComment,
            targets: targets,
            commentsByTarget: commentsByTarget
        )
    }
}

public enum GenotypeMatrixReviewCapability {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    public typealias Review = GenotypeAnnotationSidecar.MatrixReviewAnnotation
    public typealias Comment = GenotypeAnnotationSidecar.MatrixComment

    private static let readOnlyReason = "This bundle is read-only."
    private static let emptySelectionReason = "Select one or more matrix targets."
    private static let cellOnlyReason = "Review classifications are available only for genotype cells."
    private static let mixedEvidenceReason =
        "Selection contains cells with and without read support. Review classifications require one evidence state."

    public static func evaluate(
        selection: [Target],
        evidence: GenotypeMatrixEvidenceIndex,
        reviews: [Review],
        comments: [Comment],
        isWritable: Bool
    ) -> GenotypeMatrixReviewCapabilityState {
        let targets = normalized(selection)
        let shape = selectionShape(targets)
        let reviewsByTarget = Dictionary(reviews.map { ($0.target, $0) }, uniquingKeysWith: { _, latest in latest })
        let commentsByTarget = resolvedComments(comments)
        let reviewState = valueState(targets.map { reviewsByTarget[$0]?.disposition })
        let commentState = valueState(targets.map { commentsByTarget[$0]?.body })

        var supportedCount = 0
        var unsupportedCount = 0
        var unknownCount = 0
        for target in targets {
            guard case .cell = target else {
                unknownCount += 1
                continue
            }
            if evidence.isSupported(target) {
                supportedCount += 1
            } else {
                unsupportedCount += 1
            }
        }
        let support = GenotypeMatrixSupportSummary(
            supportedCount: supportedCount,
            unsupportedCount: unsupportedCount,
            unknownCount: unknownCount
        )

        let reviewCommands = reviewCommandAvailability(
            shape: shape,
            support: support,
            isWritable: isWritable
        )
        let mutationGate: GenotypeMatrixCommandAvailability
        if !isWritable {
            mutationGate = .disabled(reason: readOnlyReason)
        } else if targets.isEmpty {
            mutationGate = .disabled(reason: emptySelectionReason)
        } else {
            mutationGate = .enabled
        }

        let clearReview: GenotypeMatrixCommandAvailability
        if mutationGate != .enabled {
            clearReview = mutationGate
        } else if shape != .cells {
            clearReview = .disabled(reason: cellOnlyReason)
        } else if reviewsByTarget.keys.contains(where: Set(targets).contains) {
            clearReview = .enabled
        } else {
            clearReview = .disabled(reason: "No review marks to clear.")
        }

        let removeComments = commentRemovalAvailability(
            mutationGate: mutationGate,
            targets: targets,
            commentsByTarget: commentsByTarget
        )

        return GenotypeMatrixReviewCapabilityState(
            selectionShape: shape,
            selectedCellCount: shape == .cells ? targets.count : targets.reduce(0) {
                if case .cell = $1 { return $0 + 1 }
                return $0
            },
            support: support,
            reviewState: reviewState,
            commentState: commentState,
            commentsByTarget: commentsByTarget,
            isWritable: isWritable,
            falsePositive: reviewCommands.falsePositive,
            falseNegative: reviewCommands.falseNegative,
            clearReview: clearReview,
            upsertComment: mutationGate,
            removeComments: removeComments
        )
    }

    private static func normalized(_ targets: [Target]) -> [Target] {
        var seen: Set<Target> = []
        return targets.filter { seen.insert($0).inserted }
    }

    private static func selectionShape(_ targets: [Target]) -> GenotypeMatrixSelectionShape {
        guard let first = targets.first else { return .none }
        let firstKind = targetKind(first)
        guard targets.dropFirst().allSatisfy({ targetKind($0) == firstKind }) else { return .mixed }
        return firstKind
    }

    private static func targetKind(_ target: Target) -> GenotypeMatrixSelectionShape {
        switch target {
        case .cell:
            return .cells
        case .row:
            return .rows
        case .column:
            return .columns
        }
    }

    private static func reviewCommandAvailability(
        shape: GenotypeMatrixSelectionShape,
        support: GenotypeMatrixSupportSummary,
        isWritable: Bool
    ) -> (
        falsePositive: GenotypeMatrixCommandAvailability,
        falseNegative: GenotypeMatrixCommandAvailability
    ) {
        guard isWritable else {
            return (
                .disabled(reason: readOnlyReason),
                .disabled(reason: readOnlyReason)
            )
        }
        guard shape != .none else {
            return (
                .disabled(reason: emptySelectionReason),
                .disabled(reason: emptySelectionReason)
            )
        }
        guard shape == .cells else {
            return (
                .disabled(reason: cellOnlyReason),
                .disabled(reason: cellOnlyReason)
            )
        }
        if support.supportedCount > 0, support.unsupportedCount > 0 {
            return (
                .disabled(reason: mixedEvidenceReason),
                .disabled(reason: mixedEvidenceReason)
            )
        }
        if support.supportedCount == support.selectedCount {
            return (
                .enabled,
                .disabled(reason: "False negative requires no read support in every selected cell.")
            )
        }
        return (
            .disabled(reason: "False positive requires read support in every selected cell."),
            .enabled
        )
    }

    private static func valueState<Value: Equatable & Sendable>(
        _ values: [Value?]
    ) -> GenotypeMatrixValueState<Value> {
        guard let first = values.first else { return .none }
        guard values.dropFirst().allSatisfy({ $0 == first }) else { return .mixed }
        return first.map(GenotypeMatrixValueState.uniform) ?? .none
    }

    fileprivate static func commentRemovalAvailability(
        mutationGate: GenotypeMatrixCommandAvailability,
        targets: [Target],
        commentsByTarget: [Target: Comment]
    ) -> GenotypeMatrixCommandAvailability {
        guard mutationGate.isEnabled else { return mutationGate }
        guard targets.contains(where: { commentsByTarget[$0] != nil }) else {
            return .disabled(reason: "No comments to remove.")
        }
        return .enabled
    }

    private static func resolvedComments(_ comments: [Comment]) -> [Target: Comment] {
        var resolved: [Target: Comment] = [:]
        for comment in comments {
            guard let existing = resolved[comment.target] else {
                resolved[comment.target] = comment
                continue
            }
            if shouldReplace(existing: existing, with: comment) {
                resolved[comment.target] = comment
            }
        }
        return resolved
    }

    private static func shouldReplace(existing: Comment, with candidate: Comment) -> Bool {
        guard let existingDate = parseTimestamp(existing.timestamp),
              let candidateDate = parseTimestamp(candidate.timestamp) else {
            return true
        }
        return candidateDate >= existingDate
    }

    private static func parseTimestamp(_ timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
}
