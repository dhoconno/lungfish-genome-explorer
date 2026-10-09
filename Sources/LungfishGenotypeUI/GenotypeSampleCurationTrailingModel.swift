import AppKit
import Combine
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
final class GenotypeSampleCurationTrailingModel: ObservableObject {
    nonisolated enum Mode: Equatable, Sendable {
        case evidence
        case compareAndCopy
    }

    @Published var mode: Mode = .evidence
    @Published private(set) var evidenceSnapshot:
        GenotypeSupportedAllelesSnapshot
    @Published private(set) var availableEvidenceHeight: CGFloat?
    @Published private(set) var usesCompactEvidenceHeight = false
    let comparison: GenotypeSampleComparisonModel

    init(
        evidenceSnapshot: GenotypeSupportedAllelesSnapshot,
        comparison: GenotypeSampleComparisonModel
    ) {
        self.evidenceSnapshot = evidenceSnapshot
        self.comparison = comparison
    }

    func showEvidence() { mode = .evidence }
    func showCompareAndCopy() { mode = .compareAndCopy }

    func updateEvidenceAvailableHeight(
        _ availableHeight: CGFloat,
        compact: Bool
    ) {
        let normalizedHeight = availableHeight.isFinite
            ? max(1, availableHeight)
            : nil
        guard self.availableEvidenceHeight != normalizedHeight
                || usesCompactEvidenceHeight != compact else {
            return
        }
        self.availableEvidenceHeight = normalizedHeight
        usesCompactEvidenceHeight = compact
    }

    func refreshEvidence(
        target: GenotypeSupportedAllelesSnapshot,
        comparisonTargetRows: [GenotypeSampleEvidenceRow],
        selectedSourceRows: [GenotypeSampleEvidenceRow]?,
        orderedVisibleRowIDs: [GenotypeCandidateMatrixRowID]? = nil
    ) {
        evidenceSnapshot = target
        comparison.refreshTargetRows(
            comparisonTargetRows,
            selectedSourceRows: selectedSourceRows,
            orderedVisibleRowIDs: orderedVisibleRowIDs
        )
    }
}
