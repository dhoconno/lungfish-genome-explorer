import Foundation

/// Reads matrix annotations saved before N9 at the locus their call has now.
///
/// A matrix row or cell target stores the locus of its call. Before N9 a
/// full-length call's locus came from its genotype alone, so a review,
/// comment or style saved then names the accession's pseudo-locus, for
/// example `MHC-NHP01270`, while the call now sits at `MHC-A`. The sidecar
/// is never rewritten, because replayed commands compare and hash it as
/// saved. Readers pass it through `readView(of:)` instead, which moves a
/// known call's target from its genotype-only locus to its current locus.
/// When the sidecar holds an entry at both loci for one target, the entry
/// at the current locus is the one read.
///
/// The alias is empty for every call that was not stamped, so amplicon
/// results and full-length results without a record store read their
/// sidecars unchanged.
public struct GenotypeMatrixTargetLocusAlias: Sendable, Equatable {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget

    private struct LegacyKey: Hashable, Sendable {
        let locus: String
        let genotype: String
    }

    /// The current locus of each stamped call, by its genotype-only locus and
    /// genotype.
    private let currentLocusByLegacyKey: [LegacyKey: String]
    /// The genotype-only loci of each stamped call, by its current locus and
    /// genotype. The reverse of `currentLocusByLegacyKey`.
    private let legacyLociByCurrentKey: [LegacyKey: [String]]

    /// The alias of a result with no stamped calls. It moves no target.
    public static let empty = GenotypeMatrixTargetLocusAlias(calls: [])

    public init(calls: [ONTGenotypeCall]) {
        var aliases: [LegacyKey: String] = [:]
        var reverse: [LegacyKey: [String]] = [:]
        for call in calls where call.sourceLocus != nil {
            let legacy = call.genotypeLocusGroup
            let current = call.locusGroup
            guard legacy != current else { continue }
            let legacyKey = Self.key(locus: legacy, genotype: call.genotype)
            guard aliases[legacyKey] == nil else { continue }
            aliases[legacyKey] = current
            reverse[Self.key(locus: current, genotype: call.genotype), default: []].append(legacyKey.locus)
        }
        currentLocusByLegacyKey = aliases
        legacyLociByCurrentKey = reverse
    }

    public init(result: ONTGenotypeResultBundleData) {
        self.init(calls: result.calls)
    }

    /// True when no call of the result moved locus.
    public var isEmpty: Bool { currentLocusByLegacyKey.isEmpty }

    /// The target at its call's current locus. A target that names no moved
    /// call, a candidate target and a column target return unchanged.
    public func current(_ target: Target) -> Target {
        guard !isEmpty else { return target }
        switch target {
        case let .row(locus, genotype, nil):
            guard let current = currentLocusByLegacyKey[Self.key(locus: locus, genotype: genotype)] else { return target }
            return .row(locus: current, genotype: genotype)
        case let .cell(locus, genotype, sample, nil):
            guard let current = currentLocusByLegacyKey[Self.key(locus: locus, genotype: genotype)] else { return target }
            return .cell(locus: current, genotype: genotype, sample: sample)
        default:
            return target
        }
    }

    /// The targets an annotation for `current` may have been saved at before
    /// N9, at its call's genotype-only locus. Clearing a review or removing a
    /// comment at the current target removes these too, or the saved entry
    /// would come back on the next read. Empty for a target that names no
    /// moved call, a candidate target and a column target.
    public func savedTargets(for current: Target) -> [Target] {
        guard !isEmpty else { return [] }
        switch current {
        case let .row(locus, genotype, nil):
            return (legacyLociByCurrentKey[Self.key(locus: locus, genotype: genotype)] ?? [])
                .map { .row(locus: $0, genotype: genotype) }
        case let .cell(locus, genotype, sample, nil):
            return (legacyLociByCurrentKey[Self.key(locus: locus, genotype: genotype)] ?? [])
                .map { .cell(locus: $0, genotype: genotype, sample: sample) }
        default:
            return []
        }
    }

    /// The reviews with their targets at the current locus.
    public func currentReviews(
        _ reviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]
    ) -> [GenotypeAnnotationSidecar.MatrixReviewAnnotation] {
        moved(reviews, target: \.target) { review, target in
            var moved = review
            moved.target = target
            return moved
        }
    }

    /// The sidecar as readers see it, with every matrix style, comment and
    /// review target at its call's current locus. Never save this copy. The
    /// stored sidecar keeps its original targets.
    public func readView(of sidecar: GenotypeAnnotationSidecar) -> GenotypeAnnotationSidecar {
        guard !isEmpty else { return sidecar }
        var view = sidecar
        view.matrixStyles = moved(sidecar.matrixStyles, target: \.target) {
            .init(target: $1, style: $0.style, author: $0.author, timestamp: $0.timestamp)
        }
        view.matrixComments = moved(sidecar.matrixComments, target: \.target) {
            .init(target: $1, body: $0.body, author: $0.author, timestamp: $0.timestamp)
        }
        view.matrixReviews = currentReviews(sidecar.matrixReviews)
        return view
    }

    /// The read view of an optional sidecar together with targets to reload,
    /// each moved to its call's current locus. The matrix view applies a
    /// sidecar through this.
    public func readView(
        of sidecar: GenotypeAnnotationSidecar?,
        reloading targets: [Target]?
    ) -> (sidecar: GenotypeAnnotationSidecar?, targets: [Target]?) {
        (sidecar.map(readView(of:)), targets?.map(current))
    }

    /// Each matrix style's saved target beside the target it is read at.
    /// Clearing a style matches the read target and removes the saved one.
    public func styleTargets(in sidecar: GenotypeAnnotationSidecar) -> [(saved: Target, read: Target)] {
        sidecar.matrixStyles.map { ($0.target, current($0.target)) }
    }

    /// The reviews and resolved comments of the read view, keyed by target.
    public func reviewAndCommentIndexes(
        of sidecar: GenotypeAnnotationSidecar
    ) -> (reviews: [Target: [GenotypeAnnotationSidecar.MatrixReviewAnnotation]],
          comments: [Target: GenotypeAnnotationSidecar.MatrixComment]) {
        let view = readView(of: sidecar)
        return (Dictionary(grouping: view.matrixReviews, by: \.target), view.resolvedMatrixComments)
    }

    /// Moves each entry to its current target and drops a moved entry whose
    /// current target already has an entry saved there.
    private func moved<Entry>(
        _ entries: [Entry],
        target: (Entry) -> Target,
        rebuild: (Entry, Target) -> Entry
    ) -> [Entry] {
        guard !isEmpty else { return entries }
        let savedTargets = Set(entries.map(target))
        return entries.compactMap { entry in
            let original = target(entry)
            let current = self.current(original)
            guard current != original else { return entry }
            guard !savedTargets.contains(current) else { return nil }
            return rebuild(entry, current)
        }
    }

    private static func key(locus: String, genotype: String) -> LegacyKey {
        LegacyKey(locus: GenotypeHaplotypeLocusResolver.canonicalLocusName(locus), genotype: genotype)
    }
}
