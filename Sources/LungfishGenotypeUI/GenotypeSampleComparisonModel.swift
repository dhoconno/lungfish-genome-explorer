import Combine
import Foundation
import LungfishIO

struct GenotypeSampleEvidenceRow: Identifiable, Equatable, Sendable {
    struct Indicators: OptionSet, Equatable, Sendable {
        let rawValue: UInt8

        static let falsePositive = Indicators(rawValue: 1 << 0)
        static let falseNegative = Indicators(rawValue: 1 << 1)
        static let comment = Indicators(rawValue: 1 << 2)
    }

    let id: GenotypeCandidateMatrixRowID
    let allele: String
    let readSupport: Int?
    let indicators: Indicators
    let accessibilityLabel: String
    let semanticQualifiers: [String]
    let commentCounts: GenotypeMatrixScopedCommentCounts

    init(
        id: GenotypeCandidateMatrixRowID,
        allele: String,
        readSupport: Int?,
        indicators: Indicators,
        accessibilityLabel: String,
        semanticQualifiers: [String] = [],
        commentCounts: GenotypeMatrixScopedCommentCounts = .zero
    ) {
        self.id = id
        self.allele = allele
        self.readSupport = readSupport
        self.indicators = indicators
        self.accessibilityLabel = accessibilityLabel
        self.semanticQualifiers = semanticQualifiers
        self.commentCounts = commentCounts
    }
}

struct GenotypeSampleComparisonRow: Identifiable, Equatable, Sendable {
    enum Relationship: Equatable, Sendable {
        case shared
        case targetOnly
        case sourceOnly
    }

    let id: GenotypeCandidateMatrixRowID
    let allele: String
    let targetReadSupport: String
    let sourceReadSupport: String
    let relationship: Relationship
    let indicatorSummary: String?
    let semanticQualifiers: [String]
    let targetCommentCounts: GenotypeMatrixScopedCommentCounts
    let sourceCommentCounts: GenotypeMatrixScopedCommentCounts
    let targetAccessibilityLabel: String?
    let sourceAccessibilityLabel: String?
}

@MainActor
final class GenotypeSampleComparisonModel: ObservableObject {
    enum SlotOutcome: Equatable, Sendable {
        case fillsEmpty
        case replaces(String)
        case sameAssignment
        case unavailableHiddenMetadata
    }

    struct AssignmentChoice: Identifiable, Equatable, Sendable {
        let address: GenotypeManualHaplotypeDraft.SlotAddress
        let sourceLabel: String?
        let targetLabel: String?
        let outcome: SlotOutcome
        let isSelectable: Bool

        var id: GenotypeManualHaplotypeDraft.SlotAddress { address }
    }

    struct PendingSelectiveCopy: Equatable, Sendable {
        let sourceSample: String
        let addresses: Set<GenotypeManualHaplotypeDraft.SlotAddress>
        let sourceValues: [
            GenotypeManualHaplotypeDraft.SlotAddress:
                ManualHaplotypeAssignment
        ]
        let targetDraftRevision: UUID
    }

    struct Summary: Equatable, Sendable {
        let shared: Int
        let targetOnly: Int
        let sourceOnly: Int

        static let empty = Summary(
            shared: 0,
            targetOnly: 0,
            sourceOnly: 0
        )
    }

    struct StateSnapshot: Equatable, Sendable {
        let selectedSource: String?
        let comparisonRows: [GenotypeSampleComparisonRow]
    }

    private struct CandidateRecord: Sendable {
        let presentation:
            GenotypeManualHaplotypeEditorModel.CopyCandidate
        let normalizedSearchKey: String
    }

    let targetSample: String

    @Published private(set) var filteredCandidates:
        [GenotypeManualHaplotypeEditorModel.CopyCandidate]
    @Published private(set) var selectedSource: String?
    @Published private(set) var comparisonRows:
        [GenotypeSampleComparisonRow] = []
    @Published private(set) var summary: Summary = .empty
    @Published private(set) var pendingSource: String?
    @Published private(set) var confirmationText: String?
    @Published private(set) var stagedStatus: String?
    @Published private(set) var searchText = ""
    @Published private(set) var assignmentChoices: [AssignmentChoice] = []
    @Published private(set) var selectedSlotAddresses:
        Set<GenotypeManualHaplotypeDraft.SlotAddress> = []
    @Published private(set) var pendingSelectiveCopy:
        PendingSelectiveCopy?

    private var targetRows: [GenotypeSampleEvidenceRow]
    private var selectedSourceRows: [GenotypeSampleEvidenceRow] = []
    private var orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]?
    private var candidateRecords: [CandidateRecord]
    private var candidateSamples: Set<String>
    private let rowsForSource: (String) -> [GenotypeSampleEvidenceRow]
    private var targetSlots: [
        GenotypeManualHaplotypeDraft.SlotAddress:
            GenotypeManualHaplotypeDraft.SlotSnapshot
    ]
    private var targetDraftRevision: UUID
    private let isReadOnly: Bool
    private var assignmentsForSource:
        ((String) ->
            GenotypeManualHaplotypeAssignmentIndex.SampleAssignments?)?
    private var selectedSourceAssignments:
        GenotypeManualHaplotypeAssignmentIndex.SampleAssignments?
    private let stageSelectedAssignments:
        ((PendingSelectiveCopy) ->
            GenotypeManualHaplotypeDraft.SelectiveCopyResult)?
    private let isDraftDirty: () -> Bool
    private let legacyStageAssignments: ((String) -> Void)?

#if DEBUG
    private(set) var candidateSearchKeyBuildCount = 0
    private(set) var searchEvaluationCount = 1
    private var testingSourceSnapshotBuildCount = 0
    private var testingComparisonEvidenceRowInspectionCount = 0
#endif

    var stateSnapshot: StateSnapshot {
        StateSnapshot(
            selectedSource: selectedSource,
            comparisonRows: comparisonRows
        )
    }

    var canStageSelected: Bool {
        !isReadOnly
            && pendingSource == nil
            && !selectedSlotAddresses.isEmpty
    }

    init(
        targetSample: String,
        targetRows: [GenotypeSampleEvidenceRow],
        candidates: [
            GenotypeManualHaplotypeEditorModel.CopyCandidate
        ],
        orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]? = nil,
        rowsForSource: @escaping (String) -> [GenotypeSampleEvidenceRow],
        isDraftDirty: @escaping () -> Bool,
        stageAssignments: @escaping (String) -> Void
    ) {
        self.targetSample = targetSample
        self.targetRows = targetRows
        self.orderedVisibleRowIDs = orderedVisibleRowIDs
        self.rowsForSource = rowsForSource
        self.isDraftDirty = isDraftDirty
        self.legacyStageAssignments = stageAssignments
        self.targetSlots = [:]
        self.targetDraftRevision = UUID()
        self.isReadOnly = false
        self.assignmentsForSource = nil
        self.selectedSourceAssignments = nil
        self.stageSelectedAssignments = nil

        let records = Self.candidateRecords(
            from: candidates,
            excluding: targetSample
        )
        candidateRecords = records
        candidateSamples = Set(records.map(\.presentation.sample))
        filteredCandidates = records.map(\.presentation)
#if DEBUG
        candidateSearchKeyBuildCount = records.count
#endif
    }

    init(
        targetSample: String,
        targetRows: [GenotypeSampleEvidenceRow],
        candidates: [
            GenotypeManualHaplotypeEditorModel.CopyCandidate
        ],
        orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]? = nil,
        rowsForSource: @escaping (String) -> [GenotypeSampleEvidenceRow],
        targetSlots: [
            GenotypeManualHaplotypeDraft.SlotAddress:
                GenotypeManualHaplotypeDraft.SlotSnapshot
        ],
        targetDraftRevision: UUID,
        isReadOnly: Bool,
        assignmentsForSource: @escaping (String) ->
            GenotypeManualHaplotypeAssignmentIndex.SampleAssignments?,
        stageSelectedAssignments: @escaping (
            PendingSelectiveCopy
        ) -> GenotypeManualHaplotypeDraft.SelectiveCopyResult
    ) {
        self.targetSample = targetSample
        self.targetRows = targetRows
        self.orderedVisibleRowIDs = orderedVisibleRowIDs
        self.rowsForSource = rowsForSource
        self.targetSlots = targetSlots
        self.targetDraftRevision = targetDraftRevision
        self.isReadOnly = isReadOnly
        self.assignmentsForSource = assignmentsForSource
        self.selectedSourceAssignments = nil
        self.stageSelectedAssignments = stageSelectedAssignments
        self.isDraftDirty = { false }
        self.legacyStageAssignments = nil

        let records = Self.candidateRecords(
            from: candidates,
            excluding: targetSample
        )
        candidateRecords = records
        candidateSamples = Set(records.map(\.presentation.sample))
        filteredCandidates = records.map(\.presentation)
#if DEBUG
        candidateSearchKeyBuildCount = records.count
#endif
    }

    func updateSearch(_ query: String) {
        guard query != searchText else { return }
        searchText = query
#if DEBUG
        searchEvaluationCount += 1
#endif
        applySearchFilter()
    }

    private func applySearchFilter() {
        let normalized = Self.normalizedSearchKey(searchText)
        guard !normalized.isEmpty else {
            filteredCandidates = candidateRecords.map(\.presentation)
            return
        }
        filteredCandidates = candidateRecords.compactMap { record in
            record.normalizedSearchKey.contains(normalized)
                ? record.presentation
                : nil
        }
    }

    func selectSource(_ sample: String?) {
        guard pendingSource == nil else { return }
        let validatedSample = sample.flatMap {
            candidateSamples.contains($0) ? $0 : nil
        }
        guard validatedSample != selectedSource else { return }
        if selectedSource != nil {
            stagedStatus = nil
        }
        selectedSource = validatedSample
        selectedSlotAddresses = []
        if let validatedSample {
#if DEBUG
            testingSourceSnapshotBuildCount += 1
#endif
            selectedSourceRows = rowsForSource(validatedSample)
            selectedSourceAssignments =
                assignmentsForSource?(validatedSample)
        } else {
            selectedSourceRows = []
            selectedSourceAssignments = nil
        }
        rebuildAssignmentChoices()
        rebuildComparison()
    }

    func setSelected(
        _ isSelected: Bool,
        at address: GenotypeManualHaplotypeDraft.SlotAddress
    ) {
        guard pendingSource == nil,
              assignmentChoices.first(where: {
                  $0.address == address
              })?.isSelectable == true else {
            return
        }
        if isSelected {
            selectedSlotAddresses.insert(address)
        } else {
            selectedSlotAddresses.remove(address)
        }
    }

    func selectAssigned(in locus: GenotypeManualHaplotypeLocus) {
        guard pendingSource == nil else { return }
        let eligible = assignmentChoices.lazy.filter {
            $0.address.locus == locus && $0.isSelectable
        }.map(\.address)
        selectedSlotAddresses.formUnion(eligible)
    }

    func selectAllAssigned() {
        guard pendingSource == nil else { return }
        selectedSlotAddresses = Set(
            assignmentChoices.lazy.filter(\.isSelectable).map(\.address)
        )
    }

    func requestStageSelected() {
        guard canStageSelected,
              let selectedSource,
              let selectedSourceAssignments else {
            return
        }
        let addresses = selectedSlotAddresses
        let sourceValues = Dictionary(
            uniqueKeysWithValues: addresses.compactMap { address in
                selectedSourceAssignments[address.locus, address.slot].map {
                    (address, $0)
                }
            }
        )
        guard sourceValues.count == addresses.count else {
            rebuildAssignmentChoices()
            return
        }
        let request = PendingSelectiveCopy(
            sourceSample: selectedSource,
            addresses: addresses,
            sourceValues: sourceValues,
            targetDraftRevision: targetDraftRevision
        )
        pendingSelectiveCopy = request
        pendingSource = selectedSource
        let count = addresses.count
        confirmationText =
            "Stage \(count) selected assignment"
            + "\(count == 1 ? "" : "s") from \(selectedSource)?"
    }

    func confirmStageSelected() {
        guard let request = pendingSelectiveCopy,
              let stageSelectedAssignments else {
            return
        }
        pendingSelectiveCopy = nil
        pendingSource = nil
        confirmationText = nil
        let result = stageSelectedAssignments(request)
        selectedSlotAddresses = []
        rebuildAssignmentChoices()

        let applied = result.applied.count
        let skipped = result.skipped.count
        stagedStatus =
            "\(applied) assignment\(applied == 1 ? "" : "s") staged, "
            + "\(skipped) skipped from \(request.sourceSample)."
    }

    func cancelStageSelected() {
        guard pendingSelectiveCopy != nil else { return }
        pendingSelectiveCopy = nil
        pendingSource = nil
        confirmationText = nil
    }

    func requestUseAssignments() {
        if stageSelectedAssignments != nil {
            requestStageSelected()
            return
        }
        guard pendingSource == nil,
              let selectedSource else {
            return
        }
        pendingSource = selectedSource
        if isDraftDirty() {
            confirmationText =
                "Replace the current draft with all 14 haplotype slots from "
                + "\(selectedSource)? Blank source slots will clear the "
                + "corresponding draft slots."
            return
        }
        consumePendingCopy()
    }

    func confirmUseAssignments() {
        if pendingSelectiveCopy != nil {
            confirmStageSelected()
            return
        }
        guard pendingSource != nil else { return }
        consumePendingCopy()
    }

    func cancelUseAssignments() {
        if pendingSelectiveCopy != nil {
            cancelStageSelected()
            return
        }
        pendingSource = nil
        confirmationText = nil
    }

    func refreshTargetRows(_ rows: [GenotypeSampleEvidenceRow]) {
        targetRows = rows
        if let selectedSource {
#if DEBUG
            testingSourceSnapshotBuildCount += 1
#endif
            selectedSourceRows = rowsForSource(selectedSource)
            selectedSourceAssignments =
                assignmentsForSource?(selectedSource)
        } else {
            selectedSourceRows = []
            selectedSourceAssignments = nil
        }
        rebuildAssignmentChoices()
        rebuildComparison()
    }

    func refreshTargetRows(
        _ rows: [GenotypeSampleEvidenceRow],
        selectedSourceRows refreshedSourceRows: [GenotypeSampleEvidenceRow]?,
        orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]? = nil
    ) {
        targetRows = rows
        if let orderedVisibleRowIDs {
            self.orderedVisibleRowIDs = orderedVisibleRowIDs
        }
        selectedSourceRows =
            selectedSource == nil ? [] : (refreshedSourceRows ?? [])
        if let selectedSource {
            selectedSourceAssignments =
                assignmentsForSource?(selectedSource)
        } else {
            selectedSourceAssignments = nil
        }
        rebuildAssignmentChoices()
        rebuildComparison()
    }

    func refreshTargetDraft(
        slots: [
            GenotypeManualHaplotypeDraft.SlotAddress:
                GenotypeManualHaplotypeDraft.SlotSnapshot
        ],
        revision: UUID
    ) {
        targetSlots = slots
        targetDraftRevision = revision
        rebuildAssignmentChoices()
    }

    func refreshCandidates(
        _ candidates: [
            GenotypeManualHaplotypeEditorModel.CopyCandidate
        ],
        assignmentsForSource refreshedAssignmentsForSource:
            ((String) ->
                GenotypeManualHaplotypeAssignmentIndex.SampleAssignments?)?
                = nil
    ) {
        if let refreshedAssignmentsForSource {
            assignmentsForSource = refreshedAssignmentsForSource
        }
        let records = Self.candidateRecords(
            from: candidates,
            excluding: targetSample
        )
        candidateRecords = records
        candidateSamples = Set(records.map(\.presentation.sample))
#if DEBUG
        candidateSearchKeyBuildCount += records.count
#endif
        applySearchFilter()

        guard let selectedSource else {
            assignmentChoices = []
            selectedSlotAddresses = []
            return
        }
        guard candidateSamples.contains(selectedSource) else {
            self.selectedSource = nil
            selectedSourceRows = []
            selectedSourceAssignments = nil
            assignmentChoices = []
            selectedSlotAddresses = []
            pendingSelectiveCopy = nil
            pendingSource = nil
            confirmationText = nil
            stagedStatus = nil
            rebuildComparison()
            return
        }

        selectedSourceAssignments =
            assignmentsForSource?(selectedSource)
        selectedSourceRows = rowsForSource(selectedSource)
        rebuildAssignmentChoices()
        rebuildComparison()
    }

    func saveCompleted() {
        stagedStatus = nil
    }

    private func consumePendingCopy() {
        guard let source = pendingSource,
              let legacyStageAssignments else {
            return
        }
        pendingSource = nil
        confirmationText = nil
        legacyStageAssignments(source)
        stagedStatus = "Assignments staged from \(source)."
    }

    private func rebuildAssignmentChoices() {
        guard selectedSource != nil else {
            assignmentChoices = []
            selectedSlotAddresses = []
            return
        }

        assignmentChoices =
            GenotypeManualHaplotypeDraft.orderedSlotAddresses.map {
                address in
                let source =
                    selectedSourceAssignments?[
                        address.locus,
                        address.slot
                    ]
                let target = targetSlots[address]
                let outcome = slotOutcome(
                    sourceLabel: source?.label,
                    target: target
                )
                return AssignmentChoice(
                    address: address,
                    sourceLabel: source?.label,
                    targetLabel: target?.label,
                    outcome: outcome,
                    isSelectable:
                        source != nil
                        && outcome != .unavailableHiddenMetadata
                )
            }
        let selectable = Set(
            assignmentChoices.lazy.filter(\.isSelectable).map(\.address)
        )
        if pendingSelectiveCopy == nil {
            selectedSlotAddresses.formIntersection(selectable)
        }
    }

    private func slotOutcome(
        sourceLabel: String?,
        target: GenotypeManualHaplotypeDraft.SlotSnapshot?
    ) -> SlotOutcome {
        guard let sourceLabel else {
            return .sameAssignment
        }
        if target?.hasHiddenCompatibilityMetadata == true,
           target?.label == nil {
            return .unavailableHiddenMetadata
        }
        guard let targetLabel = target?.label else {
            return .fillsEmpty
        }
        if Self.normalizedLabel(sourceLabel)
            == Self.normalizedLabel(targetLabel) {
            return .sameAssignment
        }
        if target?.hasHiddenCompatibilityMetadata == true {
            return .unavailableHiddenMetadata
        }
        return .replaces(targetLabel)
    }

    private func rebuildComparison() {
        guard selectedSource != nil else {
            comparisonRows = []
            summary = .empty
            return
        }
#if DEBUG
        testingComparisonEvidenceRowInspectionCount +=
            targetRows.count + selectedSourceRows.count
#endif

        let targetByID = firstRowsByID(targetRows)
        let sourceByID = firstRowsByID(selectedSourceRows)
        let targetIDs = Set(targetByID.keys)
        let sourceIDs = Set(sourceByID.keys)
        var seen = Set<GenotypeCandidateMatrixRowID>()
        let comparisonIDs = targetIDs.union(sourceIDs)
        let visibleOrder = (orderedVisibleRowIDs ?? []).compactMap {
            comparisonIDs.contains($0) && seen.insert($0).inserted
                ? $0
                : nil
        }
        let orderedIDs = visibleOrder
            + targetRows.compactMap { row in
                seen.insert(row.id).inserted ? row.id : nil
            }
            + selectedSourceRows.compactMap { row in
                seen.insert(row.id).inserted ? row.id : nil
            }

        comparisonRows = orderedIDs.compactMap { id in
            let target = targetByID[id]
            let source = sourceByID[id]
            guard let display = target ?? source else { return nil }
            let relationship: GenotypeSampleComparisonRow.Relationship
            switch (targetIDs.contains(id), sourceIDs.contains(id)) {
            case (true, true):
                relationship = .shared
            case (true, false):
                relationship = .targetOnly
            case (false, true):
                relationship = .sourceOnly
            case (false, false):
                return nil
            }
            return GenotypeSampleComparisonRow(
                id: id,
                allele: display.allele,
                targetReadSupport: readSupportText(target),
                sourceReadSupport: readSupportText(source),
                relationship: relationship,
                indicatorSummary: indicatorSummary(
                    target: target,
                    source: source
                ),
                semanticQualifiers: uniqueQualifiers(
                    target: target,
                    source: source
                ),
                targetCommentCounts: target?.commentCounts ?? .zero,
                sourceCommentCounts: source?.commentCounts ?? .zero,
                targetAccessibilityLabel: target?.accessibilityLabel,
                sourceAccessibilityLabel: source?.accessibilityLabel
            )
        }
        summary = Summary(
            shared: comparisonRows.lazy.filter {
                $0.relationship == .shared
            }.count,
            targetOnly: comparisonRows.lazy.filter {
                $0.relationship == .targetOnly
            }.count,
            sourceOnly: comparisonRows.lazy.filter {
                $0.relationship == .sourceOnly
            }.count
        )
    }

    private func firstRowsByID(
        _ rows: [GenotypeSampleEvidenceRow]
    ) -> [GenotypeCandidateMatrixRowID: GenotypeSampleEvidenceRow] {
        var result:
            [GenotypeCandidateMatrixRowID: GenotypeSampleEvidenceRow] = [:]
        for row in rows where result[row.id] == nil {
            result[row.id] = row
        }
        return result
    }

    private func readSupportText(
        _ row: GenotypeSampleEvidenceRow?
    ) -> String {
        guard let row else { return "—" }
        if row.indicators.contains(.falseNegative) {
            return "FN"
        }
        guard let readSupport = row.readSupport else { return "—" }
        return readSupport.formatted(.number)
    }

    private func indicatorSummary(
        target: GenotypeSampleEvidenceRow?,
        source: GenotypeSampleEvidenceRow?
    ) -> String? {
        let targetIndicators = indicatorLabels(target?.indicators ?? [])
        let sourceIndicators = indicatorLabels(source?.indicators ?? [])
        var components: [String] = []
        if !targetIndicators.isEmpty {
            components.append(
                "Target: \(targetIndicators.joined(separator: ", "))"
            )
        }
        if !sourceIndicators.isEmpty {
            components.append(
                "Source: \(sourceIndicators.joined(separator: ", "))"
            )
        }
        return components.isEmpty
            ? nil
            : components.joined(separator: "; ")
    }

    private func indicatorLabels(
        _ indicators: GenotypeSampleEvidenceRow.Indicators
    ) -> [String] {
        var labels: [String] = []
        if indicators.contains(.falsePositive) {
            labels.append("FP")
        }
        if indicators.contains(.falseNegative) {
            labels.append("FN")
        }
        if indicators.contains(.comment) {
            labels.append("comment")
        }
        return labels
    }

    private func uniqueQualifiers(
        target: GenotypeSampleEvidenceRow?,
        source: GenotypeSampleEvidenceRow?
    ) -> [String] {
        var seen = Set<String>()
        return ((target?.semanticQualifiers ?? [])
            + (source?.semanticQualifiers ?? [])).filter {
                seen.insert($0).inserted
            }
    }

    private static func normalizedSearchKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static func normalizedLabel(_ value: String) -> String {
        if let normalized = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: value) {
            return normalized
        }
        return normalizedSearchKey(value)
    }

    private static func candidateRecords(
        from candidates: [
            GenotypeManualHaplotypeEditorModel.CopyCandidate
        ],
        excluding targetSample: String
    ) -> [CandidateRecord] {
        var seenSamples = Set<String>()
        return candidates.compactMap { candidate in
            guard candidate.sample != targetSample,
                  seenSamples.insert(candidate.sample).inserted else {
                return nil
            }
            return CandidateRecord(
                presentation: candidate,
                normalizedSearchKey: normalizedSearchKey(
                    [
                        candidate.sample,
                        candidate.completenessSummary,
                        candidate.compactSummary,
                    ].joined(separator: " ")
                )
            )
        }
    }
}

#if DEBUG
extension GenotypeSampleComparisonModel {
    struct TestingPerformanceCounters: Equatable {
        let sourceSnapshotBuildCount: Int
        let comparisonEvidenceRowInspectionCount: Int
    }

    var testingPerformanceCounters: TestingPerformanceCounters {
        TestingPerformanceCounters(
            sourceSnapshotBuildCount: testingSourceSnapshotBuildCount,
            comparisonEvidenceRowInspectionCount:
                testingComparisonEvidenceRowInspectionCount
        )
    }

    func testingResetPerformanceCounters() {
        testingSourceSnapshotBuildCount = 0
        testingComparisonEvidenceRowInspectionCount = 0
    }
}
#endif
