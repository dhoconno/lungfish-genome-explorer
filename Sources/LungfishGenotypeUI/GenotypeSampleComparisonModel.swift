import Combine
import Foundation

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
}

@MainActor
final class GenotypeSampleComparisonModel: ObservableObject {
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

    private var targetRows: [GenotypeSampleEvidenceRow]
    private var selectedSourceRows: [GenotypeSampleEvidenceRow] = []
    private var orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]?
    private let candidateRecords: [CandidateRecord]
    private let candidateSamples: Set<String>
    private let rowsForSource: (String) -> [GenotypeSampleEvidenceRow]
    private let isDraftDirty: () -> Bool
    private let stageAssignments: (String) -> Void

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
        self.stageAssignments = stageAssignments

        var seenSamples = Set<String>()
        let records = candidates.compactMap {
            candidate -> CandidateRecord? in
            guard candidate.sample != targetSample,
                  seenSamples.insert(candidate.sample).inserted else {
                return nil
            }
            return CandidateRecord(
                presentation: candidate,
                normalizedSearchKey: Self.normalizedSearchKey(
                    [
                        candidate.sample,
                        candidate.completenessSummary,
                        candidate.compactSummary,
                    ].joined(separator: " ")
                )
            )
        }
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
        let normalized = Self.normalizedSearchKey(query)
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
        let validatedSample = sample.flatMap {
            candidateSamples.contains($0) ? $0 : nil
        }
        guard validatedSample != selectedSource else { return }
        if selectedSource != nil {
            stagedStatus = nil
        }
        selectedSource = validatedSample
        if let validatedSample {
#if DEBUG
            testingSourceSnapshotBuildCount += 1
#endif
            selectedSourceRows = rowsForSource(validatedSample)
        } else {
            selectedSourceRows = []
        }
        rebuildComparison()
    }

    func requestUseAssignments() {
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
        guard pendingSource != nil else { return }
        consumePendingCopy()
    }

    func cancelUseAssignments() {
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
        } else {
            selectedSourceRows = []
        }
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
        rebuildComparison()
    }

    func saveCompleted() {
        stagedStatus = nil
    }

    private func consumePendingCopy() {
        guard let source = pendingSource else { return }
        pendingSource = nil
        confirmationText = nil
        stageAssignments(source)
        stagedStatus = "Assignments staged from \(source)."
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
                )
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

    private static func normalizedSearchKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
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
