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
                       rationale: String) throws {
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

    func confirmCall(sample: String, locus: String, h1: String, h2: String) throws {
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

    func undoLastOverride() throws {
        guard let last = sidecar.callOverrides.popLast() else { return }
        let timestamp = now()
        sidecar.append(audit: .init(
            action: "undoOverride", sample: last.sample, locus: last.locus, slot: last.slot,
            before: last.overrideCall, after: last.originalCall,
            color: nil, reason: nil, rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "undoLastOverride")
    }

    func setSampleStatus(_ value: GenotypeAnnotationSidecar.StatusValue, sample: String) throws {
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
                       sample: String, locus: String, slot: HaplotypeSlot) throws {
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
                          fillHex: String?, borderHex: String?) throws {
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

    func addCellComment(sample: String, locus: String, slot: HaplotypeSlot, body: String) throws {
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
        style: GenotypeAnnotationSidecar.MatrixStyle?
    ) throws {
        try setMatrixStyles([(target: target, style: style)])
    }

    func setMatrixStyles(
        _ edits: [(target: GenotypeAnnotationSidecar.MatrixTarget, style: GenotypeAnnotationSidecar.MatrixStyle?)]
    ) throws {
        guard !edits.isEmpty else { return }
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

    func addMatrixComment(target: GenotypeAnnotationSidecar.MatrixTarget, body: String) throws {
        try addMatrixComments([(target: target, body: body)])
    }

    func addMatrixComments(
        _ edits: [(target: GenotypeAnnotationSidecar.MatrixTarget, body: String)]
    ) throws {
        guard !edits.isEmpty else { return }
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

    func addSampleNote(sample: String, body: String) throws {
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

    func updateSettings(_ mutate: (inout GenotypeAnnotationSidecar.Settings) -> Void) throws {
        let before = sidecar.settings
        mutate(&sidecar.settings)
        guard sidecar.settings != before else { return }
        let timestamp = now()
        sidecar.append(audit: .init(
            action: "updateSettings", sample: "bundle", locus: nil, slot: nil,
            before: settingsSummary(before), after: settingsSummary(sidecar.settings),
            color: nil, reason: "settings", rationale: nil,
            author: author, timestamp: timestamp
        ))
        try persist(action: "updateSettings")
    }

    func updateMHCCandidateDisplaySettings(_ display: ONTMHCCandidateDisplaySettings) throws {
        guard !isReadOnly else { return }
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

    func saveSmartCohort(_ cohort: GenotypeCohortSmartFilter) throws {
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

    func deleteSmartCohort(name: String, scope: String) throws {
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

    func addManualHaplotypeAssignment(_ assignment: ManualHaplotypeAssignment) throws {
        sidecar.manualHaplotypeAssignments.append(assignment)
        appendManualHaplotypeAssignmentAudit(action: "addManualHaplotypeAssignment",
                                             assignment: assignment,
                                             before: nil,
                                             after: assignment.label,
                                             timestamp: now())
        try persist(action: "addManualHaplotypeAssignment")
    }

    func removeManualHaplotypeAssignments(matching predicate: (ManualHaplotypeAssignment) -> Bool) throws {
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
                                                 timestamp: timestamp)
        }
        try persist(action: "removeManualHaplotypeAssignments")
    }

    /// Removes the call override for the given (sample, locus, slot) and
    /// appends a "clearOverride" audit entry that records the previous
    /// override and the call it reverts to. A no-op if no override exists.
    func clearOverride(sample: String, locus: String, slot: HaplotypeSlot) throws {
        guard let existing = sidecar.callOverrides.first(where: {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }) else { return }
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
    func addManualHaplotypeAssignments(_ assignments: [ManualHaplotypeAssignment]) throws {
        guard !assignments.isEmpty else { return }
        let timestamp = now()
        sidecar.manualHaplotypeAssignments.append(contentsOf: assignments)
        for assignment in assignments {
            appendManualHaplotypeAssignmentAudit(action: "addManualHaplotypeAssignment",
                                                 assignment: assignment,
                                                 before: nil,
                                                 after: assignment.label,
                                                 timestamp: timestamp)
        }
        try persist(action: "addManualHaplotypeAssignments")
    }

    private func appendManualHaplotypeAssignmentAudit(
        action: String,
        assignment: ManualHaplotypeAssignment,
        before: String?,
        after: String?,
        timestamp: String
    ) {
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

    private struct ProvenanceEditContext {
        var explicitOptions: [String: ParameterValue]
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
        let priorInput = snapshot.annotationData.map {
            provenanceDescriptor(data: $0, url: annotationURL, role: .input)
        }
        let output = provenanceDescriptor(data: annotationData, url: annotationURL, role: .output)
        let envelope = makeAnnotationProvenance(
            sidecar: sidecar,
            action: action,
            annotationURL: annotationURL,
            priorInput: priorInput,
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
        priorInput: ProvenanceFileDescriptor?,
        output: ProvenanceFileDescriptor,
        editContext: ProvenanceEditContext?,
        startedAt: Date,
        endedAt: Date
    ) -> ProvenanceEnvelope {
        let argv = [
            CLICommandIdentity.executableName,
            "genotype",
            "apply-annotations",
            "--bundle", bundleURL.path,
            "--patch", annotationURL.path,
        ]
        var explicitOptions: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "annotationSidecar": .file(annotationURL),
            "patch": .file(annotationURL),
            "action": .string(action),
        ]
        if let editContext {
            explicitOptions.merge(editContext.explicitOptions) { _, payload in payload }
        }
        let inputs = [priorInput].compactMap { $0 }
        let wallTime = max(0, endedAt.timeIntervalSince(startedAt))
        let step = ProvenanceStep(
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
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
            argv: argv,
            options: ProvenanceOptions(
                explicit: explicitOptions,
                defaults: [
                    "format": .string("json"),
                    "sidecarFilename": .string(GenotypeAnnotationSidecar.filename),
                ],
                resolvedDefaults: [
                    "author": .string(author),
                    "auditEntryCount": .integer(sidecar.auditLog.count),
                    "callOverrideCount": .integer(sidecar.callOverrides.count),
                    "matrixStyleCount": .integer(sidecar.matrixStyles.count),
                    "matrixCommentCount": .integer(sidecar.matrixComments.count),
                    "manualHaplotypeAssignmentCount": .integer(sidecar.manualHaplotypeAssignments.count),
                    "smartCohortCount": .integer(sidecar.smartCohorts.count),
                ]
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
