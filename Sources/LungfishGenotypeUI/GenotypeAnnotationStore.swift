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

@Observable
@MainActor
public final class GenotypeAnnotationStore {
    public private(set) var sidecar: GenotypeAnnotationSidecar
    public let bundleURL: URL
    public let author: String

    @ObservationIgnored
    private var lastPersistedSidecar: GenotypeAnnotationSidecar

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
        try self.init(bundleURL: bundleURL, author: author, publicationFaultInjector: nil)
    }

    init(
        bundleURL: URL,
        author: String,
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
        if !isReadOnly {
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
        let author = editAuthor ?? self.author
        let timestamp = now()
        let existing = sidecar.callOverrides.first {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
        let automatedCall = existing?.originalCall ?? originalCall
        let auditBefore = existing?.overrideCall ?? automatedCall
        sidecar.callOverrides.removeAll {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
        if overrideCall == automatedCall {
            guard existing != nil else { return }
            sidecar.append(audit: .init(
                action: "clearOverride", sample: sample, locus: locus, slot: slot,
                before: auditBefore, after: automatedCall,
                color: nil, reason: reasonTag.rawValue, rationale: rationale,
                author: author, timestamp: timestamp
            ))
            try persist(action: "clearOverride")
            return
        }
        let entry = GenotypeAnnotationSidecar.CallOverride(
            sample: sample, locus: locus, slot: slot,
            originalCall: automatedCall, overrideCall: overrideCall,
            reasonTag: reasonTag, rationale: rationale,
            author: author, timestamp: timestamp
        )
        sidecar.callOverrides.append(entry)
        sidecar.append(audit: .init(
            action: "override", sample: sample, locus: locus, slot: slot,
            before: auditBefore, after: overrideCall,
            color: nil, reason: reasonTag.rawValue, rationale: rationale,
            author: author, timestamp: timestamp
        ))
        try persist(action: "applyOverride")
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
        let normalizedTargets = try normalizedMatrixTargets(targets)
        guard normalizedTargets.allSatisfy({
            if case .cell = $0 { return true }
            return false
        }) else {
            throw GenotypeMatrixReviewMutationError.invalidReviewTargets
        }
        let editAuthor = author
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

            let existing = Dictionary(
                latest.matrixReviews.map { ($0.target, $0.disposition) },
                uniquingKeysWith: { _, newest in newest }
            )
            let beforeValues = normalizedTargets.map { existing[$0]?.rawValue }
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeReviews = latest.matrixReviews.filter { $0.target == target }
                latest.matrixReviews.removeAll { $0.target == target }
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
    }

    public func clearMatrixReview(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) async throws {
        let normalizedTargets = try normalizedMatrixTargets(targets)
        guard normalizedTargets.allSatisfy({
            if case .cell = $0 { return true }
            return false
        }) else {
            throw GenotypeMatrixReviewMutationError.invalidReviewTargets
        }
        let editAuthor = author
        try transactMatrixMutation(action: "clearMatrixReview") { latest, timestamp in
            let existing = Dictionary(
                latest.matrixReviews.map { ($0.target, $0.disposition) },
                uniquingKeysWith: { _, newest in newest }
            )
            let beforeValues = normalizedTargets.map { existing[$0]?.rawValue }
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeReviews = latest.matrixReviews.filter { $0.target == target }
                latest.matrixReviews.removeAll { $0.target == target }
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
    }

    public func upsertMatrixComment(
        body: String,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenotypeMatrixReviewMutationError.emptyCommentBody
        }
        let normalizedTargets = try normalizedMatrixTargets(targets)
        let editAuthor = author
        try transactMatrixMutation(action: "upsertMatrixComment") { latest, timestamp in
            let currentComments = latest.resolvedMatrixComments
            let beforeValues = normalizedTargets.map { currentComments[$0]?.body }
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeComments = latest.matrixComments.filter { $0.target == target }
                let canonicalizationAudits = canonicalizeLegacyMatrixComments(
                    in: &latest,
                    target: target,
                    current: currentComments[target],
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.matrixComments.removeAll { $0.target == target }
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
    }

    public func removeMatrixComments(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        author: String
    ) async throws {
        let normalizedTargets = try normalizedMatrixTargets(targets)
        let editAuthor = author
        try transactMatrixMutation(action: "removeMatrixComment") { latest, timestamp in
            let currentComments = latest.resolvedMatrixComments
            let beforeValues = normalizedTargets.map { currentComments[$0]?.body }
            var targetMutations: [GenotypeMatrixAnnotationReplayPayload.TargetMutation] = []
            for target in normalizedTargets {
                let beforeComments = latest.matrixComments.filter { $0.target == target }
                let canonicalizationAudits = canonicalizeLegacyMatrixComments(
                    in: &latest,
                    target: target,
                    current: currentComments[target],
                    author: editAuthor,
                    timestamp: timestamp
                )
                latest.matrixComments.removeAll { $0.target == target }
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

    /// Removes the call override for the given (sample, locus, slot) and
    /// appends a "clearOverride" audit entry that records the previous
    /// override and the call it reverts to. A no-op if no override exists.
    func clearOverride(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        author editAuthor: String? = nil
    ) throws {
        guard let existing = sidecar.callOverrides.first(where: {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }) else { return }
        let author = editAuthor ?? self.author
        sidecar.callOverrides.removeAll {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
        sidecar.append(audit: .init(
            action: "clearOverride", sample: sample, locus: locus, slot: slot,
            before: existing.overrideCall, after: existing.originalCall,
            color: nil, reason: existing.reasonTag.rawValue, rationale: nil,
            author: author, timestamp: now()
        ))
        try persist(action: "clearOverride")
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
            }
        } catch {
            sidecar = latestForRollback
            lastPersistedSidecar = latestForRollback
            throw error
        }
    }

    private func canonicalizeLegacyMatrixComments(
        in sidecar: inout GenotypeAnnotationSidecar,
        target: GenotypeAnnotationSidecar.MatrixTarget,
        current: GenotypeAnnotationSidecar.MatrixComment?,
        author: String,
        timestamp: String
    ) -> [GenotypeAnnotationSidecar.AuditEntry] {
        let indexedComments = sidecar.matrixComments.enumerated().filter { $0.element.target == target }
        guard indexedComments.count > 1, let current else { return [] }
        let currentIndex = indexedComments.last(where: { $0.element == current })?.offset
        var appended: [GenotypeAnnotationSidecar.AuditEntry] = []
        for (index, superseded) in indexedComments where index != currentIndex {
            let alreadyRepresented = sidecar.auditLog.contains { audit in
                isMatrixCommentHistory(audit)
                    && audit.rationale == target.stableAuditDescription
                    && (audit.before == superseded.body || audit.after == superseded.body)
            }
            guard !alreadyRepresented else { continue }
            let audit = GenotypeAnnotationSidecar.AuditEntry(
                action: "canonicalizeLegacyMatrixComments",
                sample: target.auditSample,
                locus: target.locus,
                slot: nil,
                before: superseded.body,
                after: current.body,
                color: nil,
                reason: "legacy-matrix-comment",
                rationale: target.stableAuditDescription,
                author: author,
                timestamp: timestamp
            )
            sidecar.append(audit: audit)
            appended.append(audit)
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
        var resolvedAuthor: String?
        var replayPayload: GenotypeMatrixAnnotationReplayPayload?

        init(
            explicitOptions: [String: ParameterValue],
            resolvedAuthor: String? = nil,
            replayPayload: GenotypeMatrixAnnotationReplayPayload? = nil
        ) {
            self.explicitOptions = explicitOptions
            self.resolvedAuthor = resolvedAuthor
            self.replayPayload = replayPayload
        }
    }

    private func persist(action: String, editContext: ProvenanceEditContext? = nil) throws {
        guard !isReadOnly else { return }
        let startedAt = Date()
        let desiredSidecar = sidecar
        var latestForRollback = lastPersistedSidecar
        let coordinator = annotationPublicationCoordinator()
        do {
            _ = try coordinator.transact { snapshot in
                let latest = try decodedLatestSidecar(from: snapshot.annotationData)
                latestForRollback = latest
                guard latest == lastPersistedSidecar else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
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
        let replayOutputProvenanceURL =
            GenotypeMatrixAnnotationReplayPayload.replayOutputProvenanceURL(for: annotationURL)
        let durableReplayArgv: [String]?
        if editContext?.replayPayload != nil {
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
        if let replayPayload = editContext?.replayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(GenotypeMatrixAnnotationReplayPayload.format)
            explicitOptions["replayPayloadBase64"] = .string(replayData.base64EncodedString())
            explicitOptions["replayPayloadSHA256"] = .string(sha256Hex(replayData))
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
            exitStatus: 0
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
