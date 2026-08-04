import CryptoKit
import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

private enum GenotypeAnnotationStorePersistenceError: Error, LocalizedError {
    case staleRevision

    var errorDescription: String? {
        switch self {
        case .staleRevision:
            return "The genotype annotations changed in another process. Reload the bundle before saving this edit."
        }
    }
}

public enum GenotypeMatrixReviewMutationError: Error, Equatable, LocalizedError {
    case readOnly
    case emptyTargets
    case invalidReviewTargets
    case ineligibleEvidence
    case emptyCommentBody

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This bundle is read-only."
        case .emptyTargets:
            return "Select one or more matrix targets."
        case .invalidReviewTargets:
            return "Review classifications are available only for genotype cells."
        case .ineligibleEvidence:
            return "Every selected cell must satisfy the requested review classification's evidence rule."
        case .emptyCommentBody:
            return "A matrix comment cannot be empty."
        }
    }
}

public enum ManualHaplotypeReplacementError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case readOnly
    case emptySample
    case emptyAuthor
    case emptyCopySource
    case assignmentSampleMismatch(expected: String, actual: String)
    case invalidLocus(String)
    case invalidColorToken(Int)
    case duplicateKey(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    )
    case missingPriorSidecar

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "This bundle is read-only."
        case .emptySample:
            return "A manual haplotype assignment sample must not be empty."
        case .emptyAuthor:
            return "A manual haplotype assignment author must not be empty."
        case .emptyCopySource:
            return "A copied manual haplotype assignment source sample must not be empty."
        case let .assignmentSampleMismatch(expected, actual):
            return "Manual haplotype assignment sample \(actual) does not match \(expected)."
        case .invalidLocus(let locus):
            return "Manual haplotype assignment locus \(locus) is not recognized."
        case .invalidColorToken(let index):
            return "Manual haplotype assignment color token \(index) is not in the canonical palette."
        case let .duplicateKey(sample, locus, slot):
            return "Manual haplotype assignment \(sample), \(locus.rawValue), \(slot.rawValue) appears more than once."
        case .missingPriorSidecar:
            return "Manual haplotype assignments require an existing annotation sidecar before they can be saved."
        }
    }
}

public struct ManualHaplotypeReplacementResult: Equatable, Sendable {
    public let didChange: Bool
    public let sample: String
    public let operationID: String?
    public let timestamp: String?
    public let added: [ManualHaplotypeAssignment]
    public let updated: [ManualHaplotypeAssignment]
    public let removed: [ManualHaplotypeAssignment]

    public init(
        didChange: Bool,
        sample: String,
        operationID: String?,
        timestamp: String?,
        added: [ManualHaplotypeAssignment],
        updated: [ManualHaplotypeAssignment],
        removed: [ManualHaplotypeAssignment]
    ) {
        self.didChange = didChange
        self.sample = sample
        self.operationID = operationID
        self.timestamp = timestamp
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}

enum CallOverrideMutationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case readOnly
    case emptyMutations
    case emptyAuthor
    case emptyTarget
    case mixedSamples
    case duplicateTarget(GenotypeEffectiveHaplotypeKey)
    case baselineMismatch(
        target: GenotypeEffectiveHaplotypeKey,
        expected: String,
        actual: String
    )
    case missingPriorSidecar

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            "This bundle is read-only."
        case .emptyMutations:
            "A call override Save must contain at least one target."
        case .emptyAuthor:
            "A call override author must not be empty."
        case .emptyTarget:
            "Call override sample, locus, baseline, and after values must not be empty."
        case .mixedSamples:
            "One call override Save may change only one sample."
        case .duplicateTarget(let target):
            "Call override target \(target.sample), \(target.locus), \(target.slot.rawValue) appears more than once."
        case let .baselineMismatch(target, expected, actual):
            "Call override baseline changed for \(target.sample), \(target.locus), \(target.slot.rawValue): expected \(expected), found \(actual)."
        case .missingPriorSidecar:
            "Call overrides require an existing annotation sidecar before they can be saved."
        }
    }
}

struct CallOverrideMutation: Equatable, Sendable {
    let target: GenotypeEffectiveHaplotypeKey
    let baseline: String
    let after: String
    let reason: GenotypeAnnotationSidecar.OverrideReasonTag
    let rationale: String

    init(
        target: GenotypeEffectiveHaplotypeKey,
        baseline: String,
        after: String,
        reason: GenotypeAnnotationSidecar.OverrideReasonTag,
        rationale: String
    ) {
        self.target = target
        self.baseline = baseline
        self.after = after
        self.reason = reason
        self.rationale = rationale
    }
}

struct CallOverrideMutationResult: Equatable, Sendable {
    let didChange: Bool
    let changedKeys: Set<GenotypeEffectiveHaplotypeKey>
}

struct GenotypeMatrixBulkMutationDiagnostics: Equatable {
    var reviewRecordsExamined = 0
    var commentRecordsExamined = 0
    var auditRecordsExamined = 0
}

@Observable
@MainActor
public final class GenotypeAnnotationStore {
    public private(set) var sidecar: GenotypeAnnotationSidecar
    public let bundleURL: URL
    public let author: String
    public private(set) var matrixMutationRevision: UInt64 = 0
    public private(set) var manualHaplotypeAssignmentMutationRevision: UInt64 = 0
    public private(set) var callOverrideMutationRevision: UInt64 = 0

    @ObservationIgnored
    private var lastPersistedSidecar: GenotypeAnnotationSidecar

    @ObservationIgnored
    private(set) var lastMatrixBulkMutationDiagnostics = GenotypeMatrixBulkMutationDiagnostics()

    @ObservationIgnored
    private let publicationFaultInjector: GenotypeAnnotationPublicationFaultInjector?

    @ObservationIgnored
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public private(set) var isReadOnly: Bool

    public convenience init(bundleURL: URL, author: String) throws {
        try self.init(
            bundleURL: bundleURL,
            author: author,
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: nil
        )
    }

    public convenience init(
        bundleURL: URL,
        author: String,
        seedBuiltInSmartCohorts: Bool
    ) throws {
        try self.init(
            bundleURL: bundleURL,
            author: author,
            seedBuiltInSmartCohorts: seedBuiltInSmartCohorts,
            publicationFaultInjector: nil
        )
    }

    init(
        bundleURL: URL,
        author: String,
        seedBuiltInSmartCohorts: Bool = true,
        publicationFaultInjector: GenotypeAnnotationPublicationFaultInjector?
    ) throws {
        let loadedSidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        self.bundleURL = bundleURL
        self.author = author
        self.sidecar = loadedSidecar
        self.lastPersistedSidecar = loadedSidecar
        self.publicationFaultInjector = publicationFaultInjector
        // Detect read-only volumes (e.g. a mounted share) by probing the
        // bundle directory. We don't refuse to load; we just suppress
        // attempts to persist so the analyst can still browse the bundle
        // without a stream of NSAlert sheets.
        self.isReadOnly = !FileManager.default.isWritableFile(atPath: bundleURL.path)
        if !isReadOnly, seedBuiltInSmartCohorts {
            try seedBuiltInSmartCohortsIfNeeded()
        }
    }

    /// Adds the small set of default smart cohorts the spec calls out (Needs
    /// review, Homozygous, Recombinants) if the sidecar carries none. New
    /// cohorts are skipped if a cohort with the same name already exists so
    /// analysts' custom names are never overwritten.
    private func seedBuiltInSmartCohortsIfNeeded() throws {
        let builtIns: [GenotypeCohortSmartFilter] = [
            GenotypeCohortSmartFilter(
                name: "Incomplete haplotypes",
                description: "Samples with unresolved, not-assayed, or error haplotype slots.",
                scope: "bundle",
                isStarred: true,
                predicate: .needsHaplotypeReview
            ),
            GenotypeCohortSmartFilter(
                name: "Needs review",
                description: "Incomplete haplotypes, low support, or analyst-flagged samples.",
                scope: "bundle",
                isStarred: true,
                predicate: .any([
                    .needsHaplotypeReview,
                    .qcStatus([.review, .lowSupport]),
                    .hasAnalystFlag(.needsReview),
                ])
            ),
            GenotypeCohortSmartFilter(
                name: "Homozygous",
                description: "Samples whose H1 equals H2 at every called locus.",
                scope: "bundle",
                isStarred: false,
                predicate: .isHomozygousAcrossAll
            ),
            GenotypeCohortSmartFilter(
                name: "Recombinants",
                description: "Samples carrying a rec* haplotype at any locus.",
                scope: "bundle",
                isStarred: false,
                predicate: .hasRegionalRecombinant
            ),
        ]
        let existing = Set(sidecar.smartCohorts.map(\.name))
        var added = false
        for cohort in builtIns where !existing.contains(cohort.name) {
            sidecar.smartCohorts.append(cohort)
            added = true
        }
        if added {
            try persist(action: "seedBuiltInSmartCohorts")
        }
    }

    private func now() -> String { isoFormatter.string(from: Date()) }

    func applyOverride(sample: String, locus: String, slot: HaplotypeSlot,
                       originalCall: String, overrideCall: String,
                       reasonTag: GenotypeAnnotationSidecar.OverrideReasonTag,
                       rationale: String,
                       author editAuthor: String? = nil) throws {
        _ = try mutateCallOverrides(
            [
                CallOverrideMutation(
                    target: .init(
                        sample: sample,
                        locus: locus,
                        slot: slot
                    ),
                    baseline: originalCall,
                    after: overrideCall,
                    reason: reasonTag,
                    rationale: rationale
                ),
            ],
            author: editAuthor ?? self.author,
            analysisIdentity: nil
        )
    }

    func confirmCall(
        sample: String,
        locus: String,
        h1: String,
        h2: String,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        let diploidCall = "\(h1)/\(h2)"
        sidecar.callStatusFlags.removeAll {
            $0.sample == sample && $0.locus == locus && ($0.slot == .h1 || $0.slot == .h2)
        }
        sidecar.callStatusFlags.append(.init(
            sample: sample, locus: locus, slot: .h1,
            value: .confirmed, author: author, timestamp: timestamp
        ))
        sidecar.callStatusFlags.append(.init(
            sample: sample, locus: locus, slot: .h2,
            value: .confirmed, author: author, timestamp: timestamp
        ))
        sidecar.append(audit: .init(
            action: "confirmed", sample: sample, locus: locus, slot: nil,
            before: diploidCall, after: diploidCall,
            color: nil, reason: GenotypeAnnotationSidecar.OverrideReasonTag.confirmed.rawValue,
            rationale: nil, author: author, timestamp: timestamp
        ))
        try persist(action: "confirmCall")
    }

    func undoLastOverride(author editAuthor: String? = nil) throws {
        guard let last = sidecar.callOverrides.popLast() else { return }
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.append(audit: .init(
            action: "undoOverride", sample: last.sample, locus: last.locus, slot: last.slot,
            before: last.overrideCall, after: last.originalCall,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "undoLastOverride")
    }

    func setSampleStatus(
        _ value: GenotypeAnnotationSidecar.StatusValue,
        sample: String,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.sampleStatusFlags.removeAll { $0.sample == sample }
        sidecar.sampleStatusFlags.append(.init(
            sample: sample, value: value, author: author, timestamp: timestamp
        ))
        sidecar.append(audit: .init(
            action: "setSampleStatus", sample: sample, locus: nil, slot: nil,
            before: nil, after: value.rawValue,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "setSampleStatus")
    }

    func setCallStatus(_ value: GenotypeAnnotationSidecar.StatusValue,
                       sample: String, locus: String, slot: HaplotypeSlot,
                       author editAuthor: String? = nil) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.callStatusFlags.removeAll {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
        sidecar.callStatusFlags.append(.init(
            sample: sample, locus: locus, slot: slot,
            value: value, author: author, timestamp: timestamp
        ))
        sidecar.append(audit: .init(
            action: "setCallStatus", sample: sample, locus: locus, slot: slot,
            before: nil, after: value.rawValue,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "setCallStatus")
    }

    func setCellHighlight(sample: String, locus: String, slot: HaplotypeSlot,
                          fillHex: String?, borderHex: String?,
                          author editAuthor: String? = nil) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.cellHighlights.removeAll {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
        if fillHex != nil || borderHex != nil {
            sidecar.cellHighlights.append(.init(
                sample: sample, locus: locus, slot: slot,
                fillColor: fillHex, borderColor: borderHex,
                author: author, timestamp: timestamp
            ))
        }
        sidecar.append(audit: .init(
            action: "setCellHighlight", sample: sample, locus: locus, slot: slot,
            before: nil, after: nil, color: fillHex ?? borderHex,
            reason: nil, rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "setCellHighlight")
    }

    func addCellComment(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        body: String,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.cellComments.append(.init(
            sample: sample, locus: locus, slot: slot,
            body: body, author: author, timestamp: timestamp
        ))
        sidecar.append(audit: .init(
            action: "addCellComment", sample: sample, locus: locus, slot: slot,
            before: nil, after: nil, color: nil,
            reason: nil, rationale: body, author: author, timestamp: timestamp
        ))
        try persist(action: "addCellComment")
    }

    func setMatrixStyle(
        target: GenotypeAnnotationSidecar.MatrixTarget,
        style: GenotypeAnnotationSidecar.MatrixStyle?,
        author editAuthor: String? = nil
    ) throws {
        try setMatrixStyles([(target: target, style: style)], author: editAuthor)
    }

    func setMatrixStyles(
        _ edits: [(target: GenotypeAnnotationSidecar.MatrixTarget, style: GenotypeAnnotationSidecar.MatrixStyle?)],
        author editAuthor: String? = nil
    ) throws {
        guard !edits.isEmpty else { return }
        let author = editAuthor ?? self.author
        let timestamp = now()
        for edit in edits {
            let target = edit.target
            let style = edit.style
            let previous = sidecar.matrixStyles.first { $0.target == target }?.style
            sidecar.matrixStyles.removeAll { $0.target == target }
            if let style, !style.isEmpty {
                sidecar.matrixStyles.append(.init(
                    target: target,
                    style: style,
                    author: author,
                    timestamp: timestamp
                ))
            }
            sidecar.append(audit: .init(
                action: "setMatrixStyle",
                sample: target.auditSample,
                locus: target.locus,
                slot: nil,
                before: matrixStyleSummary(previous),
                after: matrixStyleSummary(style),
                color: style?.fillColor ?? style?.textColor ?? style?.borderColor,
                reason: "matrix-style",
                rationale: target.auditDescription,
                author: author,
                timestamp: timestamp
            ))
        }
        try persist(action: edits.count == 1 ? "setMatrixStyle" : "setMatrixStyles", editContext: matrixStyleEditContext(edits: edits))
    }

    func addMatrixComment(
        target: GenotypeAnnotationSidecar.MatrixTarget,
        body: String,
        author editAuthor: String? = nil
    ) throws {
        try addMatrixComments([(target: target, body: body)], author: editAuthor)
    }

    func addMatrixComments(
        _ edits: [(target: GenotypeAnnotationSidecar.MatrixTarget, body: String)],
        author editAuthor: String? = nil
    ) throws {
        guard !edits.isEmpty else { return }
        let author = editAuthor ?? self.author
        let timestamp = now()
        for edit in edits {
            let target = edit.target
            let body = edit.body
            sidecar.matrixComments.append(.init(
                target: target,
                body: body,
                author: author,
                timestamp: timestamp
            ))
            sidecar.append(audit: .init(
                action: "addMatrixComment",
                sample: target.auditSample,
                locus: target.locus,
                slot: nil,
                before: nil,
                after: body,
                color: nil,
                reason: "matrix-comment",
                rationale: target.auditDescription,
                author: author,
                timestamp: timestamp
            ))
        }
        try persist(action: edits.count == 1 ? "addMatrixComment" : "addMatrixComments", editContext: matrixCommentEditContext(edits: edits))
    }

    public func setMatrixReview(
        _ disposition: GenotypeAnnotationSidecar.MatrixReviewDisposition,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        evidence: GenotypeMatrixEvidenceIndex,
        author: String
    ) async throws {
        try setMatrixReviewSynchronously(
            disposition,
            targets: targets,
            evidence: evidence,
            author: author
        )
    }

    func setMatrixReviewSynchronously(
        _ disposition: GenotypeAnnotationSidecar.MatrixReviewDisposition,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        evidence: GenotypeMatrixEvidenceIndex,
        author: String
    ) throws {
        let normalizedTargets = try normalizedMatrixTargets(targets)
        guard normalizedTargets.allSatisfy({
            if case .cell = $0 { return true }
            return false
        }) else {
            throw GenotypeMatrixReviewMutationError.invalidReviewTargets
        }
        let editAuthor = author
        var diagnostics = GenotypeMatrixBulkMutationDiagnostics()
        try transactMatrixMutation(action: "setMatrixReview") { latest, timestamp in
            let supportedCount = normalizedTargets.reduce(0) {
                $0 + (evidence.isSupported($1) ? 1 : 0)
            }
            let unsupportedCount = normalizedTargets.count - supportedCount
            switch disposition {
            case .falsePositive:
                guard supportedCount == normalizedTargets.count else {
                    throw GenotypeMatrixReviewMutationError.ineligibleEvidence
                }
            case .falseNegative:
                guard unsupportedCount == normalizedTargets.count else {
                    throw GenotypeMatrixReviewMutationError.ineligibleEvidence
                }
            }

            let targetSet = Set(normalizedTargets)
            var retainedReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation] = []
            retainedReviews.reserveCapacity(latest.matrixReviews.count)
            var reviewsByTarget: [
                GenotypeAnnotationSidecar.MatrixTarget:
                    [GenotypeAnnotationSidecar.MatrixReviewAnnotation]
            ] = [:]
            var existing: [
                GenotypeAnnotationSidecar.MatrixTarget:
                    GenotypeAnnotationSidecar.MatrixReviewDisposition
            ] = [:]
            for review in latest.matrixReviews {
                diagnostics.reviewRecordsExamined += 1
                if targetSet.contains(review.target) {
                    reviewsByTarget[review.target, default: []].append(review)
                    existing[review.target] = review.disposition
                } else {
                    retainedReviews.append(review)
                }
            }
            let beforeValues = normalizedTargets.map { existing[$0]?.rawValue }
            latest.matrixReviews = retainedReviews
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeReviews = reviewsByTarget[target] ?? []
                let annotation = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
                    target: target,
                    disposition: disposition,
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.matrixReviews.append(annotation)
                let audit = GenotypeAnnotationSidecar.AuditEntry(
                    action: "setMatrixReview",
                    sample: target.auditSample,
                    locus: target.locus,
                    slot: nil,
                    before: existing[target]?.rawValue,
                    after: disposition.rawValue,
                    color: nil,
                    reason: "matrix-review",
                    rationale: target.stableAuditDescription,
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.append(audit: audit)
                targetMutations.append(.init(
                    target: target,
                    beforeComments: nil,
                    resolvedCurrentComment: nil,
                    afterComments: nil,
                    beforeReviews: beforeReviews,
                    afterReviews: [annotation],
                    canonicalizationAudits: [],
                    actionAudit: audit
                ))
            }
            let replayPayload = GenotypeMatrixAnnotationReplayPayload(
                action: .setMatrixReview,
                author: editAuthor,
                timestamp: timestamp,
                targetMutations: targetMutations
            )
            return matrixSemanticEditContext(
                targets: normalizedTargets,
                beforeValues: beforeValues,
                afterValues: Array(repeating: disposition.rawValue, count: normalizedTargets.count),
                author: editAuthor,
                replayPayload: replayPayload,
                extra: [
                    "disposition": .string(disposition.rawValue),
                    "eligibilityRule": .string(
                        disposition == .falsePositive
                            ? "passedUniqueReads > 0"
                            : "passedUniqueReads <= 0 or absent"
                    ),
                    "supportedCount": .integer(supportedCount),
                    "unsupportedCount": .integer(unsupportedCount),
                ]
            )
        }
        lastMatrixBulkMutationDiagnostics = diagnostics
    }

    public func clearMatrixReview(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) async throws {
        try clearMatrixReviewSynchronously(targets: targets, author: author)
    }

    func clearMatrixReviewSynchronously(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) throws {
        let normalizedTargets = try normalizedMatrixTargets(targets)
        guard normalizedTargets.allSatisfy({
            if case .cell = $0 { return true }
            return false
        }) else {
            throw GenotypeMatrixReviewMutationError.invalidReviewTargets
        }
        let editAuthor = author
        var diagnostics = GenotypeMatrixBulkMutationDiagnostics()
        try transactMatrixMutation(action: "clearMatrixReview") { latest, timestamp in
            let targetSet = Set(normalizedTargets)
            var retainedReviews: [GenotypeAnnotationSidecar.MatrixReviewAnnotation] = []
            retainedReviews.reserveCapacity(latest.matrixReviews.count)
            var reviewsByTarget: [
                GenotypeAnnotationSidecar.MatrixTarget:
                    [GenotypeAnnotationSidecar.MatrixReviewAnnotation]
            ] = [:]
            var existing: [
                GenotypeAnnotationSidecar.MatrixTarget:
                    GenotypeAnnotationSidecar.MatrixReviewDisposition
            ] = [:]
            for review in latest.matrixReviews {
                diagnostics.reviewRecordsExamined += 1
                if targetSet.contains(review.target) {
                    reviewsByTarget[review.target, default: []].append(review)
                    existing[review.target] = review.disposition
                } else {
                    retainedReviews.append(review)
                }
            }
            let beforeValues = normalizedTargets.map { existing[$0]?.rawValue }
            latest.matrixReviews = retainedReviews
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeReviews = reviewsByTarget[target] ?? []
                let audit = GenotypeAnnotationSidecar.AuditEntry(
                    action: "clearMatrixReview",
                    sample: target.auditSample,
                    locus: target.locus,
                    slot: nil,
                    before: existing[target]?.rawValue,
                    after: nil,
                    color: nil,
                    reason: "matrix-review",
                    rationale: target.stableAuditDescription,
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.append(audit: audit)
                targetMutations.append(.init(
                    target: target,
                    beforeComments: nil,
                    resolvedCurrentComment: nil,
                    afterComments: nil,
                    beforeReviews: beforeReviews,
                    afterReviews: [],
                    canonicalizationAudits: [],
                    actionAudit: audit
                ))
            }
            let replayPayload = GenotypeMatrixAnnotationReplayPayload(
                action: .clearMatrixReview,
                author: editAuthor,
                timestamp: timestamp,
                targetMutations: targetMutations
            )
            return matrixSemanticEditContext(
                targets: normalizedTargets,
                beforeValues: beforeValues,
                afterValues: Array(repeating: nil, count: normalizedTargets.count),
                author: editAuthor,
                replayPayload: replayPayload
            )
        }
        lastMatrixBulkMutationDiagnostics = diagnostics
    }

    public func upsertMatrixComment(
        body: String,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) async throws {
        try upsertMatrixCommentSynchronously(body: body, targets: targets, author: author)
    }

    func upsertMatrixCommentSynchronously(
        body: String,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenotypeMatrixReviewMutationError.emptyCommentBody
        }
        let normalizedTargets = try normalizedMatrixTargets(targets)
        let editAuthor = author
        var diagnostics = GenotypeMatrixBulkMutationDiagnostics()
        try transactMatrixMutation(action: "upsertMatrixComment") { latest, timestamp in
            diagnostics.commentRecordsExamined += latest.matrixComments.count
            let currentComments = latest.resolvedMatrixComments
            let beforeValues = normalizedTargets.map { currentComments[$0]?.body }
            let targetSet = Set(normalizedTargets)
            var retainedComments: [GenotypeAnnotationSidecar.MatrixComment] = []
            retainedComments.reserveCapacity(latest.matrixComments.count)
            var commentsByTarget: [
                GenotypeAnnotationSidecar.MatrixTarget:
                    [GenotypeAnnotationSidecar.MatrixComment]
            ] = [:]
            for comment in latest.matrixComments {
                diagnostics.commentRecordsExamined += 1
                if targetSet.contains(comment.target) {
                    commentsByTarget[comment.target, default: []].append(comment)
                } else {
                    retainedComments.append(comment)
                }
            }
            var representedHistory = matrixCommentHistoryIndex(
                latest.auditLog,
                recordsExamined: &diagnostics.auditRecordsExamined
            )
            latest.matrixComments = retainedComments
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeComments = commentsByTarget[target] ?? []
                let canonicalizationAudits = canonicalizeLegacyMatrixComments(
                    in: &latest,
                    target: target,
                    comments: beforeComments,
                    current: currentComments[target],
                    representedHistory: &representedHistory,
                    author: editAuthor,
                    timestamp: timestamp
                )
                let comment = GenotypeAnnotationSidecar.MatrixComment(
                    target: target,
                    body: body,
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.matrixComments.append(comment)
                let audit = GenotypeAnnotationSidecar.AuditEntry(
                    action: "upsertMatrixComment",
                    sample: target.auditSample,
                    locus: target.locus,
                    slot: nil,
                    before: currentComments[target]?.body,
                    after: body,
                    color: nil,
                    reason: "matrix-comment",
                    rationale: target.stableAuditDescription,
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.append(audit: audit)
                targetMutations.append(.init(
                    target: target,
                    beforeComments: beforeComments,
                    resolvedCurrentComment: currentComments[target],
                    afterComments: [comment],
                    beforeReviews: nil,
                    afterReviews: nil,
                    canonicalizationAudits: canonicalizationAudits,
                    actionAudit: audit
                ))
            }
            let replayPayload = GenotypeMatrixAnnotationReplayPayload(
                action: .upsertMatrixComment,
                author: editAuthor,
                timestamp: timestamp,
                targetMutations: targetMutations
            )
            return matrixSemanticEditContext(
                targets: normalizedTargets,
                beforeValues: beforeValues,
                afterValues: Array(repeating: body, count: normalizedTargets.count),
                author: editAuthor,
                replayPayload: replayPayload,
                extra: ["commentBody": .string(body)]
            )
        }
        lastMatrixBulkMutationDiagnostics = diagnostics
    }

    public func removeMatrixComments(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) async throws {
        try removeMatrixCommentsSynchronously(targets: targets, author: author)
    }

    func removeMatrixCommentsSynchronously(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) throws {
        let normalizedTargets = try normalizedMatrixTargets(targets)
        let editAuthor = author
        var diagnostics = GenotypeMatrixBulkMutationDiagnostics()
        try transactMatrixMutation(action: "removeMatrixComment") { latest, timestamp in
            diagnostics.commentRecordsExamined += latest.matrixComments.count
            let currentComments = latest.resolvedMatrixComments
            let beforeValues = normalizedTargets.map { currentComments[$0]?.body }
            let targetSet = Set(normalizedTargets)
            var retainedComments: [GenotypeAnnotationSidecar.MatrixComment] = []
            retainedComments.reserveCapacity(latest.matrixComments.count)
            var commentsByTarget: [
                GenotypeAnnotationSidecar.MatrixTarget:
                    [GenotypeAnnotationSidecar.MatrixComment]
            ] = [:]
            for comment in latest.matrixComments {
                diagnostics.commentRecordsExamined += 1
                if targetSet.contains(comment.target) {
                    commentsByTarget[comment.target, default: []].append(comment)
                } else {
                    retainedComments.append(comment)
                }
            }
            var representedHistory = matrixCommentHistoryIndex(
                latest.auditLog,
                recordsExamined: &diagnostics.auditRecordsExamined
            )
            latest.matrixComments = retainedComments
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeComments = commentsByTarget[target] ?? []
                let canonicalizationAudits = canonicalizeLegacyMatrixComments(
                    in: &latest,
                    target: target,
                    comments: beforeComments,
                    current: currentComments[target],
                    representedHistory: &representedHistory,
                    author: editAuthor,
                    timestamp: timestamp
                )
                let audit = GenotypeAnnotationSidecar.AuditEntry(
                    action: "removeMatrixComment",
                    sample: target.auditSample,
                    locus: target.locus,
                    slot: nil,
                    before: currentComments[target]?.body,
                    after: nil,
                    color: nil,
                    reason: "matrix-comment",
                    rationale: target.stableAuditDescription,
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.append(audit: audit)
                targetMutations.append(.init(
                    target: target,
                    beforeComments: beforeComments,
                    resolvedCurrentComment: currentComments[target],
                    afterComments: [],
                    beforeReviews: nil,
                    afterReviews: nil,
                    canonicalizationAudits: canonicalizationAudits,
                    actionAudit: audit
                ))
            }
            let replayPayload = GenotypeMatrixAnnotationReplayPayload(
                action: .removeMatrixComment,
                author: editAuthor,
                timestamp: timestamp,
                targetMutations: targetMutations
            )
            return matrixSemanticEditContext(
                targets: normalizedTargets,
                beforeValues: beforeValues,
                afterValues: Array(repeating: nil, count: normalizedTargets.count),
                author: editAuthor,
                replayPayload: replayPayload
            )
        }
        lastMatrixBulkMutationDiagnostics = diagnostics
    }

    func addSampleNote(sample: String, body: String, author editAuthor: String? = nil) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.sampleNotes.append(.init(
            sample: sample, body: body, author: author, timestamp: timestamp
        ))
        sidecar.append(audit: .init(
            action: "addSampleNote", sample: sample, locus: nil, slot: nil,
            before: nil, after: nil, color: nil,
            reason: nil, rationale: body, author: author, timestamp: timestamp
        ))
        try persist(action: "addSampleNote")
    }

    func updateSettings(
        author editAuthor: String? = nil,
        _ mutate: (inout GenotypeAnnotationSidecar.Settings) -> Void
    ) throws {
        let before = sidecar.settings
        mutate(&sidecar.settings)
        guard sidecar.settings != before else { return }
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.append(audit: .init(
            action: "updateSettings", sample: "bundle", locus: nil, slot: nil,
            before: settingsSummary(before), after: settingsSummary(sidecar.settings),
            color: nil, reason: "settings", rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "updateSettings")
    }

    func updateMHCCandidateDisplaySettings(
        _ display: ONTMHCCandidateDisplaySettings,
        author editAuthor: String? = nil
    ) throws {
        guard !isReadOnly else { return }
        let author = editAuthor ?? self.author
        let startedAt = Date()
        let timestamp = now()
        var latestForRollback = sidecar
        var publishedSidecar: GenotypeAnnotationSidecar?
        let coordinator = annotationPublicationCoordinator()
        do {
            _ = try coordinator.transact { snapshot in
                var latest = try decodedLatestSidecar(from: snapshot.annotationData)
                latestForRollback = latest
                let before = latest.settings.mhcCandidateDisplay
                guard display != before else {
                    publishedSidecar = latest
                    return nil
                }
                guard before == lastPersistedSidecar.settings.mhcCandidateDisplay else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
                latest.settings.mhcCandidateDisplay = display
                latest.append(audit: .init(
                    action: "updateMHCCandidateDisplaySettings",
                    sample: "bundle",
                    locus: nil,
                    slot: nil,
                    before: mhcCandidateDisplaySummary(before),
                    after: mhcCandidateDisplaySummary(display),
                    color: nil,
                    reason: "mhc-candidate-display-settings",
                    rationale: nil,
                    author: author,
                    timestamp: timestamp
                ))
                let payload = try annotationPublicationPayload(
                    sidecar: latest,
                    action: "updateMHCCandidateDisplaySettings",
                    editContext: mhcCandidateDisplayEditContext(display),
                    snapshot: snapshot,
                    startedAt: startedAt,
                    endedAt: Date()
                )
                publishedSidecar = latest
                return payload
            }
            if let publishedSidecar {
                sidecar = publishedSidecar
                lastPersistedSidecar = publishedSidecar
            }
        } catch {
            sidecar = latestForRollback
            lastPersistedSidecar = latestForRollback
            throw error
        }
    }

    func saveSmartCohort(
        _ cohort: GenotypeCohortSmartFilter,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        let existing = sidecar.smartCohorts.first { $0.name == cohort.name && $0.scope == cohort.scope }
        sidecar.smartCohorts.removeAll { $0.name == cohort.name && $0.scope == cohort.scope }
        sidecar.smartCohorts.append(cohort)
        let timestamp = now()
        sidecar.append(audit: .init(
            action: "saveSmartCohort", sample: "bundle", locus: nil, slot: nil,
            before: existing.map(smartCohortSummary),
            after: smartCohortSummary(cohort),
            color: nil, reason: "smartCohort", rationale: cohort.description,
            author: author, timestamp: timestamp
        ))
        try persist(action: "saveSmartCohort")
    }

    func deleteSmartCohort(
        name: String,
        scope: String,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        let existing = sidecar.smartCohorts.first { $0.name == name && $0.scope == scope }
        sidecar.smartCohorts.removeAll { $0.name == name && $0.scope == scope }
        guard let existing else { return }
        let timestamp = now()
        sidecar.append(audit: .init(
            action: "deleteSmartCohort", sample: "bundle", locus: nil, slot: nil,
            before: smartCohortSummary(existing), after: nil,
            color: nil, reason: "smartCohort", rationale: existing.description,
            author: author, timestamp: timestamp
        ))
        try persist(action: "deleteSmartCohort")
    }

    func addManualHaplotypeAssignment(
        _ assignment: ManualHaplotypeAssignment,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        sidecar.manualHaplotypeAssignments.append(assignment)
        appendManualHaplotypeAssignmentAudit(action: "addManualHaplotypeAssignment",
                                             assignment: assignment,
                                             before: nil,
                                             after: assignment.label,
                                             timestamp: now(),
                                             author: author)
        try persist(action: "addManualHaplotypeAssignment")
    }

    func removeManualHaplotypeAssignments(
        matching predicate: (ManualHaplotypeAssignment) -> Bool,
        author editAuthor: String? = nil
    ) throws {
        let author = editAuthor ?? self.author
        let timestamp = now()
        var removed: [ManualHaplotypeAssignment] = []
        sidecar.manualHaplotypeAssignments.removeAll { assignment in
            let shouldRemove = predicate(assignment)
            if shouldRemove {
                removed.append(assignment)
            }
            return shouldRemove
        }
        guard !removed.isEmpty else { return }
        for assignment in removed {
            appendManualHaplotypeAssignmentAudit(action: "removeManualHaplotypeAssignment",
                                                 assignment: assignment,
                                                 before: assignment.label,
                                                 after: nil,
                                                 timestamp: timestamp,
                                                 author: author)
        }
        try persist(action: "removeManualHaplotypeAssignments")
    }

    /// Atomically replaces the complete set of recognized manual haplotype
    /// assignments for one sample.
    ///
    /// The mutation is prepared against the publication-locked sidecar
    /// snapshot, then the sidecar and its provenance are published together.
    /// Observable state changes only after that publication succeeds.
    @discardableResult
    public func replaceManualHaplotypeAssignments(
        for sample: String,
        with draft: [ManualHaplotypeAssignment],
        copySource: String?,
        author editAuthor: String?
    ) throws -> ManualHaplotypeReplacementResult {
        guard !isReadOnly else {
            throw ManualHaplotypeReplacementError.readOnly
        }
        let normalizedSample = normalizedManualHaplotypeIdentity(sample)
        guard !normalizedSample.isEmpty else {
            throw ManualHaplotypeReplacementError.emptySample
        }
        let normalizedAuthor = normalizedManualHaplotypeIdentity(
            editAuthor ?? author
        )
        guard !normalizedAuthor.isEmpty else {
            throw ManualHaplotypeReplacementError.emptyAuthor
        }
        let normalizedCopySource: String? = try copySource.map {
            let normalized = normalizedManualHaplotypeIdentity($0)
            guard !normalized.isEmpty else {
                throw ManualHaplotypeReplacementError.emptyCopySource
            }
            return normalized
        }
        let draftByKey = try validatedManualHaplotypeDraft(
            draft,
            sample: normalizedSample
        )
        let unchangedResult = ManualHaplotypeReplacementResult(
            didChange: false,
            sample: normalizedSample,
            operationID: nil,
            timestamp: nil,
            added: [],
            updated: [],
            removed: []
        )

        let startedAt = Date()
        var publishedSidecar: GenotypeAnnotationSidecar?
        var replacementResult = unchangedResult
        let coordinator = annotationPublicationCoordinator()
        do {
            _ = try coordinator.transact { snapshot in
                guard let priorData = snapshot.annotationData else {
                    throw ManualHaplotypeReplacementError.missingPriorSidecar
                }
                var latest = try decodedLatestSidecar(from: priorData)
                guard latest == lastPersistedSidecar else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
                try latest.promoteToCurrentSchema()

                let beforeAssignments = latest.manualHaplotypeAssignments
                let recognizedBefore = beforeAssignments.filter {
                    normalizedManualHaplotypeIdentity($0.sample)
                        == normalizedSample
                        && GenotypeManualHaplotypeLocus(
                            normalizing: $0.locus
                        ) != nil
                }
                let selectedOrphans = beforeAssignments.filter {
                    normalizedManualHaplotypeIdentity($0.sample)
                        == normalizedSample
                        && GenotypeManualHaplotypeLocus(
                            normalizing: $0.locus
                        ) == nil
                }
                let beforeIndex = GenotypeManualHaplotypeAssignmentIndex(
                    assignments: recognizedBefore
                )
                let beforeByKey = beforeIndex.assignmentsByKey.filter {
                    $0.key.sample == normalizedSample
                }
                let rawBeforeByKey = Dictionary(grouping: recognizedBefore) {
                    GenotypeManualHaplotypeAssignmentKey(
                        sample: normalizedSample,
                        locus: GenotypeManualHaplotypeLocus(
                            normalizing: $0.locus
                        )!,
                        slot: $0.slot
                    )
                }

                let allKeys = Set(beforeByKey.keys).union(draftByKey.keys)
                var afterByKey: [
                    GenotypeManualHaplotypeAssignmentKey:
                        ManualHaplotypeAssignment
                ] = [:]
                var changedKeys: Set<
                    GenotypeManualHaplotypeAssignmentKey
                > = []
                let timestamp = now()
                for key in allKeys {
                    let before = beforeByKey[key]
                    guard let draftValue = draftByKey[key] else {
                        changedKeys.insert(key)
                        continue
                    }
                    let needsCanonicalization: Bool = {
                        guard let before else { return false }
                        let raw = rawBeforeByKey[key] ?? []
                        return raw.count != 1
                            || before.sample != normalizedSample
                            || before.locus != key.locus.rawValue
                            || !hasStableManualHaplotypeAssignmentID(before)
                    }()
                    let editableChanged =
                        before?.label != draftValue.label
                        || before?.colorTokenIndex != draftValue.colorTokenIndex
                    if let before, !needsCanonicalization, !editableChanged {
                        afterByKey[key] = before
                        continue
                    }
                    changedKeys.insert(key)
                    afterByKey[key] = ManualHaplotypeAssignment(
                        sample: normalizedSample,
                        locus: key.locus.rawValue,
                        slot: key.slot,
                        label: draftValue.label,
                        colorTokenIndex: draftValue.colorTokenIndex,
                        diagnosticAlleles: before?.diagnosticAlleles ?? [],
                        notes: before?.notes ?? "",
                        assignmentID:
                            stableManualHaplotypeAssignmentID(before)
                            ?? UUID().uuidString,
                        updatedAt: timestamp,
                        author: normalizedAuthor
                    )
                }

                guard !changedKeys.isEmpty else {
                    replacementResult = unchangedResult
                    return nil
                }

                let operationID = UUID().uuidString
                let priorSHA256 = sha256Hex(priorData)
                let orderedChangedKeys = changedKeys.sorted(
                    by: manualHaplotypeAssignmentKeyPrecedes
                )
                var audits: [GenotypeAnnotationSidecar.AuditEntry] = []
                var added: [ManualHaplotypeAssignment] = []
                var updated: [ManualHaplotypeAssignment] = []
                var removed: [ManualHaplotypeAssignment] = []
                audits.reserveCapacity(orderedChangedKeys.count + 1)
                for key in orderedChangedKeys {
                    let before = beforeByKey[key]
                    let after = afterByKey[key]
                    let action: String
                    switch (before, after) {
                    case (.none, .some(let after)):
                        action = "addManualHaplotypeAssignment"
                        added.append(after)
                    case (.some, .some(let after)):
                        action = "updateManualHaplotypeAssignment"
                        updated.append(after)
                    case (.some(let before), .none):
                        action = "removeManualHaplotypeAssignment"
                        removed.append(before)
                    case (.none, .none):
                        preconditionFailure(
                            "A derived changed manual assignment key must have a before or after record."
                        )
                    }
                    audits.append(GenotypeAnnotationSidecar.AuditEntry(
                        action: action,
                        sample: normalizedSample,
                        locus: key.locus.rawValue,
                        slot: key.slot,
                        before: before?.label,
                        after: after?.label,
                        color: after.map {
                            String($0.colorTokenIndex)
                        },
                        reason: "manual-haplotype-assignment",
                        rationale: normalizedCopySource.map {
                            "Copied labels and colors from \($0)."
                        },
                        author: normalizedAuthor,
                        timestamp: timestamp,
                        manualHaplotypeAssignment: .init(
                            operationID: operationID,
                            priorSidecarSHA256: priorSHA256,
                            before: before,
                            after: after,
                            copySourceSample: normalizedCopySource
                        )
                    ))
                }
                audits.append(GenotypeAnnotationSidecar.AuditEntry(
                    action: "replaceManualHaplotypeAssignments",
                    sample: normalizedSample,
                    locus: nil,
                    slot: nil,
                    before: nil,
                    after: nil,
                    color: nil,
                    reason: "manual-haplotype-assignment-batch",
                    rationale: normalizedCopySource.map {
                        "Copied labels and colors from \($0)."
                    },
                    author: normalizedAuthor,
                    timestamp: timestamp,
                    manualHaplotypeAssignment: .init(
                        operationID: operationID,
                        priorSidecarSHA256: priorSHA256,
                        before: nil,
                        after: nil,
                        copySourceSample: normalizedCopySource
                    )
                ))

                let unrelatedAssignments = beforeAssignments.filter {
                    normalizedManualHaplotypeIdentity($0.sample)
                        != normalizedSample
                }
                let orderedAfter = afterByKey
                    .sorted { manualHaplotypeAssignmentKeyPrecedes($0.key, $1.key) }
                    .map(\.value)
                latest.manualHaplotypeAssignments =
                    unrelatedAssignments + selectedOrphans + orderedAfter
                for audit in audits {
                    latest.append(audit: audit)
                }

                let manifestData = try ONTGenotypeResultBundle
                    .readManifestDataNoFollow(from: bundleURL)
                let manifestDescriptor =
                    GenotypeManualHaplotypeAssignmentReplayPayload
                        .ArtifactDescriptor(
                            path:
                                ONTGenotypeResultBundleManifest.filename,
                            checksumSHA256: sha256Hex(manifestData),
                            fileSize: UInt64(manifestData.count)
                        )
                let priorDescriptor =
                    GenotypeManualHaplotypeAssignmentReplayPayload
                        .ArtifactDescriptor(
                            path: GenotypeAnnotationSidecar.filename,
                            checksumSHA256: priorSHA256,
                            fileSize: UInt64(priorData.count)
                        )
                let replayPayload =
                    GenotypeManualHaplotypeAssignmentReplayPayload(
                        operation: .init(
                            operationID: operationID,
                            sample: normalizedSample,
                            author: normalizedAuthor,
                            timestamp: timestamp,
                            copySourceSample: normalizedCopySource
                        ),
                        targetBundle: .init(
                            bundlePath:
                                bundleURL.standardizedFileURL.path,
                            manifest: manifestDescriptor
                        ),
                        priorSidecar: .init(
                            descriptor: priorDescriptor,
                            revisionSHA256: priorSHA256
                        ),
                        beforeAssignments: beforeAssignments,
                        afterAssignments:
                            latest.manualHaplotypeAssignments,
                        auditEntries: audits
                    )
                // Validate the exact replay contract before publishing either
                // the annotation sidecar or its provenance.
                let replayed = try replayPayload.applying(
                    to: priorData,
                    targetBundleURL: bundleURL,
                    targetManifestData: manifestData
                )
                guard replayed == latest else {
                    throw GenotypeManualHaplotypeAssignmentReplayPayload
                        .ReplayError.invalidOperation(
                            "prepared GUI result does not equal its replay payload."
                        )
                }
                let editContext = manualHaplotypeReplacementEditContext(
                    replayPayload: replayPayload,
                    addedCount: added.count,
                    updatedCount: updated.count,
                    removedCount: removed.count
                )
                let publication = try annotationPublicationPayload(
                    sidecar: latest,
                    action: "replaceManualHaplotypeAssignments",
                    editContext: editContext,
                    snapshot: snapshot,
                    startedAt: startedAt,
                    endedAt: Date()
                )
                publishedSidecar = latest
                replacementResult = ManualHaplotypeReplacementResult(
                    didChange: true,
                    sample: normalizedSample,
                    operationID: operationID,
                    timestamp: timestamp,
                    added: added,
                    updated: updated,
                    removed: removed
                )
                return publication
            }
        } catch {
            // Observable state has not been touched. A stale, validation, or
            // publication failure must not masquerade as a successful
            // sidecar-change notification.
            throw error
        }

        if let publishedSidecar {
            sidecar = publishedSidecar
            lastPersistedSidecar = publishedSidecar
            manualHaplotypeAssignmentMutationRevision &+= 1
        }
        return replacementResult
    }

    /// Applies every call override from one user Save as one annotation and
    /// provenance publication. Observable state changes only after both files
    /// are durable.
    @discardableResult
    func mutateCallOverrides(
        _ mutations: [CallOverrideMutation],
        author editAuthor: String,
        analysisIdentity: GenotypeEffectiveHaplotypeIdentity?
    ) throws -> CallOverrideMutationResult {
        guard !isReadOnly else {
            throw CallOverrideMutationError.readOnly
        }
        guard !mutations.isEmpty else {
            throw CallOverrideMutationError.emptyMutations
        }
        let resolvedAuthor = editAuthor
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !resolvedAuthor.isEmpty else {
            throw CallOverrideMutationError.emptyAuthor
        }
        let selectedSamples = Set(mutations.map(\.target.sample))
        guard selectedSamples.count == 1 else {
            throw CallOverrideMutationError.mixedSamples
        }
        var seenTargets = Set<GenotypeEffectiveHaplotypeKey>()
        for mutation in mutations {
            guard !mutation.target.sample
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !mutation.target.locus
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !mutation.baseline
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !mutation.after
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CallOverrideMutationError.emptyTarget
            }
            guard seenTargets.insert(mutation.target).inserted else {
                throw CallOverrideMutationError.duplicateTarget(
                    mutation.target
                )
            }
        }

        let unchanged = CallOverrideMutationResult(
            didChange: false,
            changedKeys: []
        )
        let startedAt = Date()
        var publishedSidecar: GenotypeAnnotationSidecar?
        var mutationResult = unchanged
        let coordinator = annotationPublicationCoordinator()
        _ = try coordinator.transact { snapshot in
            guard let priorData = snapshot.annotationData else {
                throw CallOverrideMutationError.missingPriorSidecar
            }
            var latest = try decodedLatestSidecar(from: priorData)
            guard latest == lastPersistedSidecar else {
                throw GenotypeAnnotationStorePersistenceError.staleRevision
            }
            try latest.promoteToCurrentSchema()

            let priorOverrides = latest.callOverrides
            var existingByTarget: [
                GenotypeEffectiveHaplotypeKey:
                    GenotypeAnnotationSidecar.CallOverride
            ] = [:]
            for mutation in mutations {
                let matches = priorOverrides.enumerated().filter {
                    _, entry in
                    entry.sample == mutation.target.sample
                        && entry.locus == mutation.target.locus
                        && entry.slot == mutation.target.slot
                }
                if let authoritative = authoritativeCallOverride(matches) {
                    guard authoritative.originalCall
                            == mutation.baseline else {
                        throw CallOverrideMutationError.baselineMismatch(
                            target: mutation.target,
                            expected: authoritative.originalCall,
                            actual: mutation.baseline
                        )
                    }
                    existingByTarget[mutation.target] = authoritative
                }
            }
            let changedMutations = mutations.filter { mutation in
                let before = existingByTarget[mutation.target]
                if mutation.after == mutation.baseline {
                    return before != nil
                }
                guard let before else { return true }
                return before.overrideCall != mutation.after
                    || before.reasonTag != mutation.reason
                    || before.rationale != mutation.rationale
                    || before.author != resolvedAuthor
                    || before.analysisIdentity
                        != analysisIdentity?.sidecarIdentity
            }
            guard !changedMutations.isEmpty else {
                mutationResult = unchanged
                return nil
            }

            let operationID = UUID().uuidString
            let timestamp = now()
            let priorSHA256 = sha256Hex(priorData)
            let changedKeys = Set(changedMutations.map(\.target))
            let unchangedOverrides = priorOverrides.filter { entry in
                !changedKeys.contains(.init(
                    sample: entry.sample,
                    locus: entry.locus,
                    slot: entry.slot
                ))
            }
            let sidecarIdentity = analysisIdentity?.sidecarIdentity
            let replacementOverrides = changedMutations.compactMap {
                mutation -> GenotypeAnnotationSidecar.CallOverride? in
                guard mutation.after != mutation.baseline else {
                    return nil
                }
                return GenotypeAnnotationSidecar.CallOverride(
                    sample: mutation.target.sample,
                    locus: mutation.target.locus,
                    slot: mutation.target.slot,
                    originalCall: mutation.baseline,
                    overrideCall: mutation.after,
                    reasonTag: mutation.reason,
                    rationale: mutation.rationale,
                    author: resolvedAuthor,
                    timestamp: timestamp,
                    analysisIdentity: sidecarIdentity,
                    operationID: operationID
                )
            }
            latest.callOverrides = unchangedOverrides + replacementOverrides

            let audits = changedMutations.map { mutation in
                let before = existingByTarget[mutation.target]
                let restoringPipeline = mutation.after == mutation.baseline
                return GenotypeAnnotationSidecar.AuditEntry(
                    action: restoringPipeline ? "clearOverride" : "override",
                    sample: mutation.target.sample,
                    locus: mutation.target.locus,
                    slot: mutation.target.slot,
                    before: before?.overrideCall ?? mutation.baseline,
                    after: mutation.after,
                    color: nil,
                    reason: mutation.reason.rawValue,
                    rationale: restoringPipeline
                        ? "Restore pipeline call"
                        : mutation.rationale,
                    author: resolvedAuthor,
                    timestamp: timestamp,
                    callOverrideMutation: .init(
                        operationID: operationID,
                        priorSidecarSHA256: priorSHA256,
                        analysisIdentity: sidecarIdentity
                    )
                )
            }
            for audit in audits {
                latest.append(audit: audit)
            }

            let manifestData = try ONTGenotypeResultBundle
                .readManifestDataNoFollow(from: bundleURL)
            let replayMutations = zip(changedMutations, audits).map {
                mutation, audit in
                GenotypeCallOverrideReplayPayload.TargetMutation(
                    locus: mutation.target.locus,
                    slot: mutation.target.slot,
                    baseline: mutation.baseline,
                    before: audit.before ?? mutation.baseline,
                    after: mutation.after,
                    reason: mutation.reason,
                    rationale: audit.rationale ?? mutation.rationale
                )
            }
            let replayPayload = GenotypeCallOverrideReplayPayload(
                operation: .init(
                    operationID: operationID,
                    sample: changedMutations[0].target.sample,
                    author: resolvedAuthor,
                    timestamp: timestamp,
                    analysisIdentity: sidecarIdentity
                ),
                targetBundle: .init(
                    bundlePath: bundleURL.standardizedFileURL.path,
                    manifest: .init(
                        path: ONTGenotypeResultBundleManifest.filename,
                        checksumSHA256: sha256Hex(manifestData),
                        fileSize: UInt64(manifestData.count)
                    )
                ),
                priorSidecar: .init(
                    descriptor: .init(
                        path: GenotypeAnnotationSidecar.filename,
                        checksumSHA256: priorSHA256,
                        fileSize: UInt64(priorData.count)
                    ),
                    revisionSHA256: priorSHA256
                ),
                beforeOverrides: priorOverrides,
                afterOverrides: latest.callOverrides,
                targetMutations: replayMutations,
                auditEntries: audits
            )
            let replayed = try replayPayload.applying(
                to: priorData,
                targetBundleURL: bundleURL,
                targetManifestData: manifestData
            )
            guard replayed == latest else {
                throw GenotypeCallOverrideReplayPayload.ReplayError
                    .invalidOperation(
                        "prepared GUI result does not equal its replay payload."
                    )
            }
            let editContext = callOverrideMutationEditContext(
                replayPayload: replayPayload
            )
            let publication = try annotationPublicationPayload(
                sidecar: latest,
                action: "mutateCallOverrides",
                editContext: editContext,
                snapshot: snapshot,
                startedAt: startedAt,
                endedAt: Date()
            )
            publishedSidecar = latest
            mutationResult = CallOverrideMutationResult(
                didChange: true,
                changedKeys: changedKeys
            )
            return publication
        }

        if let publishedSidecar {
            sidecar = publishedSidecar
            lastPersistedSidecar = publishedSidecar
            callOverrideMutationRevision &+= 1
        }
        return mutationResult
    }

    private func authoritativeCallOverride(
        _ matches: [(offset: Int, element: GenotypeAnnotationSidecar.CallOverride)]
    ) -> GenotypeAnnotationSidecar.CallOverride? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        var selected: (
            entry: GenotypeAnnotationSidecar.CallOverride,
            date: Date,
            index: Int
        )?
        for match in matches {
            guard let date = fractional.date(
                from: match.element.timestamp
            ) ?? internet.date(from: match.element.timestamp) else {
                continue
            }
            if let current = selected,
               date < current.date
                || (date == current.date && match.offset < current.index) {
                continue
            }
            selected = (match.element, date, match.offset)
        }
        return selected?.entry
    }

    /// Removes the call override for the given (sample, locus, slot) and
    /// appends a "clearOverride" audit entry that records the previous
    /// override and the call it reverts to. A no-op if no override exists.
    func clearOverride(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        author editAuthor: String? = nil
    ) throws {
        let matches = sidecar.callOverrides.enumerated().filter {
            _, entry in
            entry.sample == sample
                && entry.locus == locus
                && entry.slot == slot
        }
        guard let existing = authoritativeCallOverride(matches) else {
            return
        }
        _ = try mutateCallOverrides(
            [
                CallOverrideMutation(
                    target: .init(
                        sample: sample,
                        locus: locus,
                        slot: slot
                    ),
                    baseline: existing.originalCall,
                    after: existing.originalCall,
                    reason: existing.reasonTag,
                    rationale: "Restore pipeline call"
                ),
            ],
            author: editAuthor ?? self.author,
            analysisIdentity: nil
        )
    }

    private func settingsSummary(_ settings: GenotypeAnnotationSidecar.Settings) -> String {
        let overrides = settings.locusFractionOverrides?
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",") ?? "nil"
        return [
            "viewMode=\(settings.viewMode)",
            "panelLayout=\(settings.panelLayout)",
            "cardDensity=\(settings.cardDensity)",
            "cardDensityThreshold=\(settings.cardDensityThreshold)",
            "dropoutAbsolute=\(optional(settings.dropoutAbsolute))",
            "dropoutSampleFraction=\(optional(settings.dropoutSampleFraction))",
            "dropoutLocusFraction=\(optional(settings.dropoutLocusFraction))",
            "locusFractionOverrides=\(overrides)",
            "activeHaplotypeDefinitionSetID=\(optional(settings.activeHaplotypeDefinitionSetID))",
            "activeHaplotypeAssayID=\(optional(settings.activeHaplotypeAssayID))",
            "preferredSummaryViewMode=\(optional(settings.preferredSummaryViewMode))",
            "mhcCandidateDisplay=\(mhcCandidateDisplaySummary(settings.mhcCandidateDisplay))",
        ].joined(separator: "; ")
    }

    private func mhcCandidateDisplaySummary(_ display: ONTMHCCandidateDisplaySettings) -> String {
        let tintSummary = ONTMHCCandidateTintCategory.allCases.map { category in
            let color = display.tints[category]
                ?? ONTMHCCandidateDisplaySettings.defaultTints[category]!
            return "\(category.rawValue)=\(mhcCandidateTintSummary(color))"
        }.joined(separator: ",")
        return [
            "showKnown=\(display.showKnown)",
            "showSharedCandidates=\(display.showSharedCandidates)",
            "showSingletonCandidates=\(display.showSingletonCandidates)",
            tintSummary,
        ].joined(separator: "; ")
    }

    private func mhcCandidateTintSummary(_ color: AnnotationColor) -> String {
        "{red=\(color.red),green=\(color.green),blue=\(color.blue),alpha=\(color.alpha),hexRGB=\(color.hexString)}"
    }

    private func smartCohortSummary(_ cohort: GenotypeCohortSmartFilter) -> String {
        [
            "name=\(cohort.name)",
            "scope=\(cohort.scope)",
            "starred=\(cohort.isStarred)",
            "predicate=\(cohort.predicate)",
            "searchProjectionText=\(cohort.searchProjectionText ?? "nil")",
        ].joined(separator: "; ")
    }

    private func optional<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    private func matrixStyleSummary(_ style: GenotypeAnnotationSidecar.MatrixStyle?) -> String? {
        guard let style else { return nil }
        var parts: [String] = []
        if let fill = style.fillColor {
            parts.append("fill=\(fill)")
        }
        if let text = style.textColor {
            parts.append("text=\(text)")
        }
        if let border = style.borderColor {
            parts.append("border=\(border)")
        }
        if style.isBold {
            parts.append("bold")
        }
        if style.isItalic {
            parts.append("italic")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "; ")
    }

    /// Bulk-add manual haplotype assignments in a single persist call.
    /// Use this instead of looping `addManualHaplotypeAssignment` when adding
    /// many at once (e.g. one assignment per sample sharing a manual haplotype).
    func addManualHaplotypeAssignments(
        _ assignments: [ManualHaplotypeAssignment],
        author editAuthor: String? = nil
    ) throws {
        guard !assignments.isEmpty else { return }
        let author = editAuthor ?? self.author
        let timestamp = now()
        sidecar.manualHaplotypeAssignments.append(contentsOf: assignments)
        for assignment in assignments {
            appendManualHaplotypeAssignmentAudit(action: "addManualHaplotypeAssignment",
                                                 assignment: assignment,
                                                 before: nil,
                                                 after: assignment.label,
                                                 timestamp: timestamp,
                                                 author: author)
        }
        try persist(action: "addManualHaplotypeAssignments")
    }

    private func appendManualHaplotypeAssignmentAudit(
        action: String,
        assignment: ManualHaplotypeAssignment,
        before: String?,
        after: String?,
        timestamp: String,
        author: String? = nil
    ) {
        let author = author ?? self.author
        let alleleSummary = assignment.diagnosticAlleles.isEmpty
            ? nil
            : "Diagnostic alleles: \(assignment.diagnosticAlleles.joined(separator: ", "))"
        let note = assignment.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale: String? = {
            switch (alleleSummary, note.isEmpty ? nil : note) {
            case let (.some(alleles), .some(note)):
                return "\(alleles). \(note)"
            case let (.some(alleles), nil):
                return alleles
            case let (nil, .some(note)):
                return note
            case (nil, nil):
                return nil
            }
        }()
        sidecar.append(audit: .init(
            action: action,
            sample: assignment.sample,
            locus: assignment.locus,
            slot: assignment.slot,
            before: before,
            after: after,
            color: nil,
            reason: "manual-haplotype-assignment",
            rationale: rationale,
            author: author,
            timestamp: timestamp
        ))
    }

    private struct ManualHaplotypeDraftValue {
        let label: String
        let colorTokenIndex: Int
    }

    private func normalizedManualHaplotypeIdentity(_ raw: String) -> String {
        GenotypeManualHaplotypeAssignmentInputValidator
            .normalizedSampleIdentity(raw)
    }

    private func validatedManualHaplotypeDraft(
        _ draft: [ManualHaplotypeAssignment],
        sample: String
    ) throws -> [
        GenotypeManualHaplotypeAssignmentKey: ManualHaplotypeDraftValue
    ] {
        let canonicalColors = Set(
            HaplotypeColorToken.canonicalPalette.map(\.canonicalIndex)
        )
        var validated: [
            GenotypeManualHaplotypeAssignmentKey: ManualHaplotypeDraftValue
        ] = [:]
        validated.reserveCapacity(draft.count)
        for assignment in draft {
            let assignmentSample = normalizedManualHaplotypeIdentity(
                assignment.sample
            )
            guard !assignmentSample.isEmpty else {
                throw ManualHaplotypeReplacementError.emptySample
            }
            guard assignmentSample == sample else {
                throw ManualHaplotypeReplacementError
                    .assignmentSampleMismatch(
                        expected: sample,
                        actual: assignmentSample
                    )
            }
            let rawLocus = assignment.locus
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !rawLocus.isEmpty,
                  let locus = GenotypeManualHaplotypeLocus(
                    normalizing: rawLocus
                  ) else {
                throw ManualHaplotypeReplacementError.invalidLocus(
                    assignment.locus
                )
            }
            guard canonicalColors.contains(assignment.colorTokenIndex) else {
                throw ManualHaplotypeReplacementError.invalidColorToken(
                    assignment.colorTokenIndex
                )
            }
            let label =
                try GenotypeManualHaplotypeAssignmentInputValidator
                    .validatedLabel(assignment.label)
            let key = GenotypeManualHaplotypeAssignmentKey(
                sample: sample,
                locus: locus,
                slot: assignment.slot
            )
            guard validated[key] == nil else {
                throw ManualHaplotypeReplacementError.duplicateKey(
                    sample: sample,
                    locus: locus,
                    slot: assignment.slot
                )
            }
            validated[key] = ManualHaplotypeDraftValue(
                label: label,
                colorTokenIndex: assignment.colorTokenIndex
            )
        }
        return validated
    }

    private func hasStableManualHaplotypeAssignmentID(
        _ assignment: ManualHaplotypeAssignment
    ) -> Bool {
        stableManualHaplotypeAssignmentID(assignment) != nil
    }

    private func stableManualHaplotypeAssignmentID(
        _ assignment: ManualHaplotypeAssignment?
    ) -> String? {
        guard let assignmentID = assignment?.assignmentID,
              !assignmentID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            return nil
        }
        return assignmentID
    }

    private func manualHaplotypeAssignmentKeyPrecedes(
        _ lhs: GenotypeManualHaplotypeAssignmentKey,
        _ rhs: GenotypeManualHaplotypeAssignmentKey
    ) -> Bool {
        if lhs.sample != rhs.sample {
            return lhs.sample.localizedStandardCompare(rhs.sample)
                == .orderedAscending
        }
        let lhsLocus = GenotypeManualHaplotypeLocus.allCases.firstIndex(
            of: lhs.locus
        ) ?? 0
        let rhsLocus = GenotypeManualHaplotypeLocus.allCases.firstIndex(
            of: rhs.locus
        ) ?? 0
        if lhsLocus != rhsLocus {
            return lhsLocus < rhsLocus
        }
        return lhs.slot == .h1 && rhs.slot == .h2
    }

    private func normalizedMatrixTargets(
        _ targets: [GenotypeAnnotationSidecar.MatrixTarget]
    ) throws -> [GenotypeAnnotationSidecar.MatrixTarget] {
        var seen: Set<GenotypeAnnotationSidecar.MatrixTarget> = []
        let normalized = targets.filter { seen.insert($0).inserted }
        guard !normalized.isEmpty else {
            throw GenotypeMatrixReviewMutationError.emptyTargets
        }
        return normalized
    }

    private func transactMatrixMutation(
        action: String,
        mutate: (
            inout GenotypeAnnotationSidecar,
            String
        ) throws -> ProvenanceEditContext
    ) throws {
        guard !isReadOnly else {
            throw GenotypeMatrixReviewMutationError.readOnly
        }
        let previousSidecar = sidecar
        let startedAt = Date()
        var latestForRollback = lastPersistedSidecar
        var publishedSidecar: GenotypeAnnotationSidecar?
        let coordinator = annotationPublicationCoordinator()
        do {
            _ = try coordinator.transact { snapshot in
                var latest = try decodedLatestSidecar(from: snapshot.annotationData)
                latestForRollback = latest
                guard latest == lastPersistedSidecar else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
                try latest.promoteToCurrentSchema()
                let timestamp = now()
                let editContext = try mutate(&latest, timestamp)
                let payload = try annotationPublicationPayload(
                    sidecar: latest,
                    action: action,
                    editContext: editContext,
                    snapshot: snapshot,
                    startedAt: startedAt,
                    endedAt: Date()
                )
                publishedSidecar = latest
                return payload
            }
            if let publishedSidecar {
                sidecar = publishedSidecar
                lastPersistedSidecar = publishedSidecar
                matrixMutationRevision &+= 1
            }
        } catch {
            sidecar = latestForRollback
            lastPersistedSidecar = latestForRollback
            if sidecar != previousSidecar {
                matrixMutationRevision &+= 1
            }
            throw error
        }
    }

    private struct MatrixCommentHistoryKey: Hashable {
        var targetDescription: String
        var body: String
    }

    private func matrixCommentHistoryIndex(
        _ auditLog: [GenotypeAnnotationSidecar.AuditEntry],
        recordsExamined: inout Int
    ) -> Set<MatrixCommentHistoryKey> {
        var represented: Set<MatrixCommentHistoryKey> = []
        for audit in auditLog {
            recordsExamined += 1
            guard isMatrixCommentHistory(audit), let targetDescription = audit.rationale else {
                continue
            }
            if let before = audit.before {
                represented.insert(.init(targetDescription: targetDescription, body: before))
            }
            if let after = audit.after {
                represented.insert(.init(targetDescription: targetDescription, body: after))
            }
        }
        return represented
    }

    private func canonicalizeLegacyMatrixComments(
        in sidecar: inout GenotypeAnnotationSidecar,
        target: GenotypeAnnotationSidecar.MatrixTarget,
        comments: [GenotypeAnnotationSidecar.MatrixComment],
        current: GenotypeAnnotationSidecar.MatrixComment?,
        representedHistory: inout Set<MatrixCommentHistoryKey>,
        author: String,
        timestamp: String
    ) -> [GenotypeAnnotationSidecar.AuditEntry] {
        guard comments.count > 1, let current else { return [] }
        let currentIndex = comments.lastIndex(of: current)
        let targetDescription = target.stableAuditDescription
        var appended: [GenotypeAnnotationSidecar.AuditEntry] = []
        for (index, superseded) in comments.enumerated() where index != currentIndex {
            let historyKey = MatrixCommentHistoryKey(
                targetDescription: targetDescription,
                body: superseded.body
            )
            guard !representedHistory.contains(historyKey) else { continue }
            let audit = GenotypeAnnotationSidecar.AuditEntry(
                action: "canonicalizeLegacyMatrixComments",
                sample: target.auditSample,
                locus: target.locus,
                slot: nil,
                before: superseded.body,
                after: current.body,
                color: nil,
                reason: "legacy-matrix-comment",
                rationale: targetDescription,
                author: author,
                timestamp: timestamp
            )
            sidecar.append(audit: audit)
            appended.append(audit)
            representedHistory.insert(historyKey)
            representedHistory.insert(.init(
                targetDescription: targetDescription,
                body: current.body
            ))
        }
        return appended
    }

    private func isMatrixCommentHistory(
        _ audit: GenotypeAnnotationSidecar.AuditEntry
    ) -> Bool {
        let recognizedAction: Bool
        switch audit.action {
        case "addMatrixComment",
             "addMatrixComments",
             "upsertMatrixComment",
             "removeMatrixComment",
             "canonicalizeLegacyMatrixComments":
            recognizedAction = true
        default:
            recognizedAction = false
        }
        return recognizedAction
            && (audit.reason == "matrix-comment" || audit.reason == "legacy-matrix-comment")
    }

    private struct ProvenanceEditContext {
        var explicitOptions: [String: ParameterValue]
        var resolvedDefaults: [String: ParameterValue]
        var resolvedAuthor: String?
        var replayPayload: GenotypeMatrixAnnotationReplayPayload?
        var manualHaplotypeReplayPayload:
            GenotypeManualHaplotypeAssignmentReplayPayload?
        var callOverrideReplayPayload:
            GenotypeCallOverrideReplayPayload?

        init(
            explicitOptions: [String: ParameterValue],
            resolvedDefaults: [String: ParameterValue] = [:],
            resolvedAuthor: String? = nil,
            replayPayload: GenotypeMatrixAnnotationReplayPayload? = nil,
            manualHaplotypeReplayPayload:
                GenotypeManualHaplotypeAssignmentReplayPayload? = nil,
            callOverrideReplayPayload:
                GenotypeCallOverrideReplayPayload? = nil
        ) {
            self.explicitOptions = explicitOptions
            self.resolvedDefaults = resolvedDefaults
            self.resolvedAuthor = resolvedAuthor
            self.replayPayload = replayPayload
            self.manualHaplotypeReplayPayload =
                manualHaplotypeReplayPayload
            self.callOverrideReplayPayload = callOverrideReplayPayload
        }
    }

    private func persist(action: String, editContext: ProvenanceEditContext? = nil) throws {
        guard !isReadOnly else { return }
        let startedAt = Date()
        var desiredSidecar = sidecar
        do {
            try desiredSidecar.promoteToCurrentSchema()
        } catch {
            sidecar = lastPersistedSidecar
            throw error
        }
        var latestForRollback = lastPersistedSidecar
        let coordinator = annotationPublicationCoordinator()
        do {
            _ = try coordinator.transact { snapshot in
                var latest = try decodedLatestSidecar(from: snapshot.annotationData)
                latestForRollback = latest
                guard latest == lastPersistedSidecar else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
                try latest.promoteToCurrentSchema()
                return try annotationPublicationPayload(
                    sidecar: desiredSidecar,
                    action: action,
                    editContext: editContext,
                    snapshot: snapshot,
                    startedAt: startedAt,
                    endedAt: Date()
                )
            }
            sidecar = desiredSidecar
            lastPersistedSidecar = desiredSidecar
        } catch {
            sidecar = latestForRollback
            lastPersistedSidecar = latestForRollback
            throw error
        }
    }

    private func annotationPublicationCoordinator() -> GenotypeAnnotationPublicationCoordinator {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        return GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundleURL,
            annotationFilename: annotationURL.lastPathComponent,
            provenanceFilename: ProvenanceRecorder.fileSidecarURL(for: annotationURL).lastPathComponent,
            faultInjector: publicationFaultInjector
        )
    }

    private func decodedLatestSidecar(from data: Data?) throws -> GenotypeAnnotationSidecar {
        guard let data else {
            return GenotypeAnnotationSidecar.empty(generatedAt: lastPersistedSidecar.generatedAt)
        }
        return try GenotypeAnnotationSidecar.decode(data)
    }

    private func annotationPublicationPayload(
        sidecar: GenotypeAnnotationSidecar,
        action: String,
        editContext: ProvenanceEditContext?,
        snapshot: GenotypeAnnotationPublicationSnapshot,
        startedAt: Date,
        endedAt: Date
    ) throws -> GenotypeAnnotationPublicationPayload {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let annotationData = try sidecar.encoded()
        let output = provenanceDescriptor(data: annotationData, url: annotationURL, role: .output)
        let envelope = try makeAnnotationProvenance(
            sidecar: sidecar,
            action: action,
            annotationURL: annotationURL,
            priorData: snapshot.annotationData,
            output: output,
            editContext: editContext,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return try GenotypeAnnotationPublicationPayload(
            annotationData: annotationData,
            provenanceData: ProvenanceJSON.encoder.encode(envelope)
        )
    }

    private func provenanceDescriptor(
        data: Data,
        url: URL,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            fileSize: UInt64(data.count),
            format: .json,
            role: role
        )
    }

    private func makeAnnotationProvenance(
        sidecar: GenotypeAnnotationSidecar,
        action: String,
        annotationURL: URL,
        priorData: Data?,
        output: ProvenanceFileDescriptor,
        editContext: ProvenanceEditContext?,
        startedAt: Date,
        endedAt: Date
    ) throws -> ProvenanceEnvelope {
        let executionArgv = CommandLine.arguments
        var explicitOptions: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "annotationSidecar": .file(annotationURL),
            "action": .string(action),
            "executionMode": .string("gui-edit"),
        ]
        if let editContext {
            explicitOptions.merge(editContext.explicitOptions) { _, payload in payload }
        }
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let durableReplayArgv: [String]?
        if editContext?.callOverrideReplayPayload != nil {
            let replayOutputProvenanceURL =
                GenotypeCallOverrideReplayPayload
                    .replayOutputProvenanceURL(
                        forBundleAt: bundleURL
                    )
            durableReplayArgv = [
                CLICommandIdentity.executableName,
                "genotype",
                GenotypeCallOverrideReplayPayload.cliSubcommandName,
                "--provenance", provenanceURL.path,
                "--bundle", bundleURL.standardizedFileURL.path,
            ]
            explicitOptions["replayOutputProvenance"] =
                .file(replayOutputProvenanceURL)
        } else if editContext?.manualHaplotypeReplayPayload != nil {
            let replayOutputProvenanceURL =
                GenotypeManualHaplotypeAssignmentReplayPayload
                    .replayOutputProvenanceURL(
                        forBundleAt: bundleURL
                    )
            durableReplayArgv = [
                CLICommandIdentity.executableName,
                "genotype",
                GenotypeManualHaplotypeAssignmentReplayPayload
                    .cliSubcommandName,
                "--provenance", provenanceURL.path,
                "--bundle", bundleURL.standardizedFileURL.path,
            ]
            explicitOptions["replayOutputProvenance"] =
                .file(replayOutputProvenanceURL)
        } else if editContext?.replayPayload != nil {
            let replayOutputProvenanceURL =
                GenotypeMatrixAnnotationReplayPayload
                    .replayOutputProvenanceURL(for: annotationURL)
            durableReplayArgv = [
                CLICommandIdentity.executableName,
                "genotype",
                GenotypeMatrixAnnotationReplayPayload.cliSubcommandName,
                "--provenance", provenanceURL.path,
                "--output", annotationURL.path,
                "--output-provenance", replayOutputProvenanceURL.path,
                "--force",
            ]
            explicitOptions["replayOutputProvenance"] = .file(replayOutputProvenanceURL)
        } else {
            durableReplayArgv = nil
        }
        let reproducibleCommand = (durableReplayArgv ?? executionArgv)
            .map(shellEscape)
            .joined(separator: " ")
        var inputs: [ProvenanceFileDescriptor] = []
        if let priorData {
            let checksum = sha256Hex(priorData)
            explicitOptions["replayPriorSidecarBase64"] = .string(priorData.base64EncodedString())
            inputs.append(ProvenanceFileDescriptor(
                path: provenanceURL.path + "#/options/explicit/replayPriorSidecarBase64",
                checksumSHA256: checksum,
                fileSize: UInt64(priorData.count),
                format: .json,
                role: .input,
                originPath: annotationURL.path
            ))
        }
        if let replayPayload = editContext?.callOverrideReplayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(
                GenotypeCallOverrideReplayPayload.format
            )
            explicitOptions["replayPayloadBase64"] = .string(
                replayData.base64EncodedString()
            )
            explicitOptions["replayPayloadSHA256"] = .string(
                sha256Hex(replayData)
            )
        } else if let replayPayload = editContext?.replayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(GenotypeMatrixAnnotationReplayPayload.format)
            explicitOptions["replayPayloadBase64"] = .string(replayData.base64EncodedString())
            explicitOptions["replayPayloadSHA256"] = .string(sha256Hex(replayData))
        } else if let replayPayload =
            editContext?.manualHaplotypeReplayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(
                GenotypeManualHaplotypeAssignmentReplayPayload.format
            )
            explicitOptions["replayPayloadBase64"] = .string(
                replayData.base64EncodedString()
            )
            explicitOptions["replayPayloadSHA256"] = .string(
                sha256Hex(replayData)
            )
        }
        if let replayPayload = editContext?.callOverrideReplayPayload {
            inputs.append(ProvenanceFileDescriptor(
                path: bundleURL.appendingPathComponent(
                    replayPayload.targetBundle.manifest.path
                ).path,
                checksumSHA256:
                    replayPayload.targetBundle.manifest.checksumSHA256,
                fileSize: replayPayload.targetBundle.manifest.fileSize,
                format: .json,
                role: .input
            ))
        } else if let replayPayload =
            editContext?.manualHaplotypeReplayPayload {
            inputs.append(ProvenanceFileDescriptor(
                path: bundleURL.appendingPathComponent(
                    replayPayload.targetBundle.manifest.path
                ).path,
                checksumSHA256:
                    replayPayload.targetBundle.manifest.checksumSHA256,
                fileSize:
                    replayPayload.targetBundle.manifest.fileSize,
                format: .json,
                role: .input
            ))
        }
        let wallTime = max(0, endedAt.timeIntervalSince(startedAt))
        let resolvedAuthor = editContext?.resolvedAuthor
            ?? sidecar.auditLog.last?.author
            ?? author
        var resolvedDefaults: [String: ParameterValue] = [
            "author": .string(resolvedAuthor),
            "auditEntryCount": .integer(sidecar.auditLog.count),
            "callOverrideCount": .integer(sidecar.callOverrides.count),
            "matrixStyleCount": .integer(sidecar.matrixStyles.count),
            "matrixCommentCount": .integer(sidecar.matrixComments.count),
            "matrixReviewCount": .integer(sidecar.matrixReviews.count),
            "manualHaplotypeAssignmentCount": .integer(sidecar.manualHaplotypeAssignments.count),
            "smartCohortCount": .integer(sidecar.smartCohorts.count),
        ]
        if let editContext {
            resolvedDefaults.merge(editContext.resolvedDefaults) {
                _, mutationValue in mutationValue
            }
        }
        if action == "setMatrixReview" {
            resolvedDefaults["absentEvidence"] = .string("unsupported")
            resolvedDefaults["supportThreshold"] = .string("passedUniqueReads > 0")
        }
        let step = ProvenanceStep(
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: executionArgv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            resolvedOptions: resolvedDefaults,
            runtimeIdentity: ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser),
            inputs: inputs,
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            startedAt: startedAt,
            completedAt: endedAt
        )
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "Genotype annotation sidecar edit",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "Lungfish Genome Explorer",
                version: WorkflowRun.currentAppVersion,
                kind: "gui"
            ),
            argv: executionArgv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: ProvenanceOptions(
                explicit: explicitOptions,
                defaults: [
                    "format": .string("json"),
                    "sidecarFilename": .string(GenotypeAnnotationSidecar.filename),
                ],
                resolvedDefaults: resolvedDefaults
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser),
            files: inputs + [output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0,
            stderr: ""
        )
    }

    private func matrixStyleEditContext(
        edits: [(target: GenotypeAnnotationSidecar.MatrixTarget, style: GenotypeAnnotationSidecar.MatrixStyle?)]
    ) -> ProvenanceEditContext {
        ProvenanceEditContext(
            explicitOptions: [
                "targetCount": .integer(edits.count),
                "targets": .array(edits.map { matrixTargetParameterValue($0.target) }),
                "styles": .array(edits.map { matrixStyleParameterValue($0.style) }),
            ]
        )
    }

    private func matrixCommentEditContext(
        edits: [(target: GenotypeAnnotationSidecar.MatrixTarget, body: String)]
    ) -> ProvenanceEditContext {
        ProvenanceEditContext(
            explicitOptions: [
                "targetCount": .integer(edits.count),
                "targets": .array(edits.map { matrixTargetParameterValue($0.target) }),
                "commentBodies": .array(edits.map { .string($0.body) }),
            ]
        )
    }

    private func matrixSemanticEditContext(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        beforeValues: [String?],
        afterValues: [String?],
        author: String,
        replayPayload: GenotypeMatrixAnnotationReplayPayload,
        extra: [String: ParameterValue] = [:]
    ) -> ProvenanceEditContext {
        var explicit: [String: ParameterValue] = [
            "targetCount": .integer(targets.count),
            "targets": .array(targets.map(matrixTargetParameterValue)),
            "before": .array(beforeValues.map { $0.map(ParameterValue.string) ?? .null }),
            "after": .array(afterValues.map { $0.map(ParameterValue.string) ?? .null }),
            "resolvedAuthor": .string(author),
            "targetMutations": .array(
                replayPayload.targetMutations.map(matrixTargetMutationParameterValue)
            ),
        ]
        explicit.merge(extra) { _, value in value }
        return ProvenanceEditContext(
            explicitOptions: explicit,
            resolvedAuthor: author,
            replayPayload: replayPayload
        )
    }

    private func manualHaplotypeReplacementEditContext(
        replayPayload: GenotypeManualHaplotypeAssignmentReplayPayload,
        addedCount: Int,
        updatedCount: Int,
        removedCount: Int
    ) -> ProvenanceEditContext {
        ProvenanceEditContext(
            explicitOptions: [
                "operationID": .string(
                    replayPayload.operation.operationID
                ),
                "sample": .string(replayPayload.operation.sample),
                "resolvedAuthor": .string(
                    replayPayload.operation.author
                ),
                "timestamp": .string(
                    replayPayload.operation.timestamp
                ),
                "copySourceSample":
                    replayPayload.operation.copySourceSample
                        .map(ParameterValue.string) ?? .null,
                "addedCount": .integer(addedCount),
                "updatedCount": .integer(updatedCount),
                "removedCount": .integer(removedCount),
                "priorSidecarSHA256": .string(
                    replayPayload.priorSidecar.descriptor
                        .checksumSHA256
                ),
                "priorSidecarRevisionSHA256": .string(
                    replayPayload.priorSidecar.revisionSHA256
                ),
                "targetManifestSHA256": .string(
                    replayPayload.targetBundle.manifest.checksumSHA256
                ),
            ],
            resolvedAuthor: replayPayload.operation.author,
            manualHaplotypeReplayPayload: replayPayload
        )
    }

    private func callOverrideMutationEditContext(
        replayPayload: GenotypeCallOverrideReplayPayload
    ) -> ProvenanceEditContext {
        let identity: ParameterValue = replayPayload.operation
            .analysisIdentity.map { identity in
                .dictionary([
                    "assayID": .string(identity.assayID),
                    "analysisRevisionID": identity.analysisRevisionID
                        .map(ParameterValue.string) ?? .null,
                    "definitionSetID": .string(identity.definitionSetID),
                ])
            } ?? .null
        let targets = replayPayload.targetMutations.map { mutation in
            ParameterValue.dictionary([
                "sample": .string(replayPayload.operation.sample),
                "locus": .string(mutation.locus),
                "slot": .string(mutation.slot.rawValue),
                "baseline": .string(mutation.baseline),
                "before": .string(mutation.before),
                "after": .string(mutation.after),
                "reason": .string(mutation.reason.rawValue),
                "rationale": .string(mutation.rationale),
            ])
        }
        return ProvenanceEditContext(
            explicitOptions: [
                "operationID": .string(
                    replayPayload.operation.operationID
                ),
                "sample": .string(replayPayload.operation.sample),
                "resolvedAuthor": .string(
                    replayPayload.operation.author
                ),
                "timestamp": .string(
                    replayPayload.operation.timestamp
                ),
                "analysisIdentity": identity,
                "targetMutations": .array(targets),
                "priorSidecarSHA256": .string(
                    replayPayload.priorSidecar.descriptor
                        .checksumSHA256
                ),
                "priorSidecarRevisionSHA256": .string(
                    replayPayload.priorSidecar.revisionSHA256
                ),
                "targetManifestSHA256": .string(
                    replayPayload.targetBundle.manifest.checksumSHA256
                ),
            ],
            resolvedDefaults: [
                "changedTargetCount": .integer(targets.count),
                "restoreRationale": .string("Restore pipeline call"),
            ],
            resolvedAuthor: replayPayload.operation.author,
            callOverrideReplayPayload: replayPayload
        )
    }

    private func matrixTargetMutationParameterValue(
        _ mutation: GenotypeMatrixAnnotationReplayPayload.TargetMutation
    ) -> ParameterValue {
        let finalValue: ParameterValue = {
            if let review = mutation.afterReviews?.last {
                return .string(review.disposition.rawValue)
            }
            if let comment = mutation.afterComments?.last {
                return .string(comment.body)
            }
            return .null
        }()
        return .dictionary([
            "target": matrixTargetParameterValue(mutation.target),
            "before": .dictionary([
                "comments": mutation.beforeComments.map {
                    .array($0.map(matrixCommentParameterValue))
                } ?? .null,
                "reviews": mutation.beforeReviews.map {
                    .array($0.map(matrixReviewParameterValue))
                } ?? .null,
            ]),
            "legacyValues": mutation.beforeComments.map {
                .array($0.map { .string($0.body) })
            } ?? .null,
            "resolvedCurrent": mutation.resolvedCurrentComment.map(
                matrixCommentParameterValue
            ) ?? .null,
            "canonicalizationActions": .array(
                mutation.canonicalizationAudits.map(matrixAuditParameterValue)
            ),
            "after": .dictionary([
                "comments": mutation.afterComments.map {
                    .array($0.map(matrixCommentParameterValue))
                } ?? .null,
                "reviews": mutation.afterReviews.map {
                    .array($0.map(matrixReviewParameterValue))
                } ?? .null,
            ]),
            "finalValue": finalValue,
        ])
    }

    private func matrixCommentParameterValue(
        _ comment: GenotypeAnnotationSidecar.MatrixComment
    ) -> ParameterValue {
        .dictionary([
            "target": matrixTargetParameterValue(comment.target),
            "body": .string(comment.body),
            "author": .string(comment.author),
            "timestamp": .string(comment.timestamp),
        ])
    }

    private func matrixReviewParameterValue(
        _ review: GenotypeAnnotationSidecar.MatrixReviewAnnotation
    ) -> ParameterValue {
        .dictionary([
            "target": matrixTargetParameterValue(review.target),
            "disposition": .string(review.disposition.rawValue),
            "author": .string(review.author),
            "timestamp": .string(review.timestamp),
        ])
    }

    private func matrixAuditParameterValue(
        _ audit: GenotypeAnnotationSidecar.AuditEntry
    ) -> ParameterValue {
        .dictionary([
            "action": .string(audit.action),
            "sample": .string(audit.sample),
            "locus": audit.locus.map(ParameterValue.string) ?? .null,
            "before": audit.before.map(ParameterValue.string) ?? .null,
            "after": audit.after.map(ParameterValue.string) ?? .null,
            "reason": audit.reason.map(ParameterValue.string) ?? .null,
            "rationale": audit.rationale.map(ParameterValue.string) ?? .null,
            "author": .string(audit.author),
            "timestamp": .string(audit.timestamp),
        ])
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func mhcCandidateDisplayEditContext(
        _ display: ONTMHCCandidateDisplaySettings
    ) -> ProvenanceEditContext {
        ProvenanceEditContext(
            explicitOptions: [
                "showKnown": .boolean(display.showKnown),
                "showSharedCandidates": .boolean(display.showSharedCandidates),
                "showSingletonCandidates": .boolean(display.showSingletonCandidates),
                "candidateTints": .dictionary(Dictionary(uniqueKeysWithValues:
                    ONTMHCCandidateTintCategory.allCases.map { category in
                        let color = display.tints[category]
                            ?? ONTMHCCandidateDisplaySettings.defaultTints[category]!
                        return (
                            category.rawValue,
                            mhcCandidateTintParameterValue(color)
                        )
                    }
                )),
            ]
        )
    }

    private func mhcCandidateTintParameterValue(_ color: AnnotationColor) -> ParameterValue {
        .dictionary([
            "red": .number(color.red),
            "green": .number(color.green),
            "blue": .number(color.blue),
            "alpha": .number(color.alpha),
            "hexRGB": .string(color.hexString),
        ])
    }

    private func matrixTargetParameterValue(_ target: GenotypeAnnotationSidecar.MatrixTarget) -> ParameterValue {
        switch target {
        case let .row(locus, genotype, stableClusterID):
            var values: [String: ParameterValue] = [
                "kind": .string("row"),
                "locus": .string(locus),
                "genotype": .string(genotype),
            ]
            if let stableClusterID { values["stableClusterID"] = .string(stableClusterID) }
            return .dictionary(values)
        case let .column(sample):
            return .dictionary([
                "kind": .string("column"),
                "sample": .string(sample),
            ])
        case let .cell(locus, genotype, sample, stableClusterID):
            var values: [String: ParameterValue] = [
                "kind": .string("cell"),
                "locus": .string(locus),
                "genotype": .string(genotype),
                "sample": .string(sample),
            ]
            if let stableClusterID { values["stableClusterID"] = .string(stableClusterID) }
            return .dictionary(values)
        }
    }

    private func matrixStyleParameterValue(_ style: GenotypeAnnotationSidecar.MatrixStyle?) -> ParameterValue {
        guard let style, !style.isEmpty else { return .null }
        return .dictionary([
            "fillColor": style.fillColor.map(ParameterValue.string) ?? .null,
            "textColor": style.textColor.map(ParameterValue.string) ?? .null,
            "borderColor": style.borderColor.map(ParameterValue.string) ?? .null,
            "isBold": .boolean(style.isBold),
            "isItalic": .boolean(style.isItalic),
            "boldOverride": style.boldOverride.map(ParameterValue.boolean) ?? .null,
            "italicOverride": style.italicOverride.map(ParameterValue.boolean) ?? .null,
        ])
    }
}
