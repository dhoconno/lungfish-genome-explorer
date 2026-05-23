import Foundation
import Observation
import LungfishCore
import LungfishIO

@Observable
@MainActor
final class GenotypeAnnotationStore {
    private(set) var sidecar: GenotypeAnnotationSidecar
    let bundleURL: URL
    let author: String

    @ObservationIgnored
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private(set) var isReadOnly: Bool

    init(bundleURL: URL, author: String) throws {
        self.bundleURL = bundleURL
        self.author = author
        self.sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
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
                name: "Needs review",
                description: "Errors, low support, or analyst-flagged samples.",
                scope: "bundle",
                isStarred: true,
                predicate: .any([
                    .hasErrorAtAnyLocus,
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
            try persist()
        }
    }

    private func now() -> String { isoFormatter.string(from: Date()) }

    func applyOverride(sample: String, locus: String, slot: HaplotypeSlot,
                       originalCall: String, overrideCall: String,
                       reasonTag: GenotypeAnnotationSidecar.OverrideReasonTag,
                       rationale: String) throws {
        let timestamp = now()
        sidecar.callOverrides.removeAll {
            $0.sample == sample && $0.locus == locus && $0.slot == slot
        }
        let entry = GenotypeAnnotationSidecar.CallOverride(
            sample: sample, locus: locus, slot: slot,
            originalCall: originalCall, overrideCall: overrideCall,
            reasonTag: reasonTag, rationale: rationale,
            author: author, timestamp: timestamp
        )
        sidecar.callOverrides.append(entry)
        sidecar.append(audit: .init(
            action: "override", sample: sample, locus: locus, slot: slot,
            before: originalCall, after: overrideCall,
            color: nil, reason: reasonTag.rawValue, rationale: rationale,
            author: author, timestamp: timestamp
        ))
        try persist()
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
        try persist()
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
        try persist()
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
        try persist()
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
        try persist()
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
        try persist()
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
        try persist()
    }

    func updateSettings(_ mutate: (inout GenotypeAnnotationSidecar.Settings) -> Void) throws {
        mutate(&sidecar.settings)
        try persist()
    }

    func saveSmartCohort(_ cohort: GenotypeCohortSmartFilter) throws {
        sidecar.smartCohorts.removeAll { $0.name == cohort.name && $0.scope == cohort.scope }
        sidecar.smartCohorts.append(cohort)
        try persist()
    }

    func deleteSmartCohort(name: String, scope: String) throws {
        sidecar.smartCohorts.removeAll { $0.name == name && $0.scope == scope }
        try persist()
    }

    func addManualHaplotypeAssignment(_ assignment: ManualHaplotypeAssignment) throws {
        sidecar.manualHaplotypeAssignments.append(assignment)
        try persist()
    }

    func removeManualHaplotypeAssignments(matching predicate: (ManualHaplotypeAssignment) -> Bool) throws {
        sidecar.manualHaplotypeAssignments.removeAll(where: predicate)
        try persist()
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
        try persist()
    }

    /// Bulk-add manual haplotype assignments in a single persist call.
    /// Use this instead of looping `addManualHaplotypeAssignment` when adding
    /// many at once (e.g. one assignment per sample sharing a manual haplotype).
    func addManualHaplotypeAssignments(_ assignments: [ManualHaplotypeAssignment]) throws {
        sidecar.manualHaplotypeAssignments.append(contentsOf: assignments)
        try persist()
    }

    private func persist() throws {
        guard !isReadOnly else { return }
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
    }
}
