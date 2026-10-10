import Foundation
import LungfishIO

/// The integrity warnings the Inspector's Genotype Display section shows.
struct GenotypeIntegrityWarningState: Equatable {
    /// Plain sentences that lead the candidate warnings, such as the shared
    /// basis rule after rejected candidate artifacts.
    var candidateLead: [String] = []
    /// The full-length candidate section's warnings.
    var candidate: [ONTGenotypeIntegrityWarning] = []
    /// Warnings that hold for every bundle type, such as the duplicate-row
    /// warning (D5b).
    var result: [ONTGenotypeIntegrityWarning] = []
    /// Warnings about the annotation sidecar read against the result, such
    /// as analyst edits saved at an old per-reference locus (N9).
    var annotation: [ONTGenotypeIntegrityWarning] = []

    init() {}

    init(result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar?) {
        let candidate = GenotypeResultDisplaySectionViewModel.candidateWarnings(for: result)
        candidateLead = candidate.lead
        self.candidate = candidate.warnings
        self.result = GenotypeResultDisplaySectionViewModel.resultWarnings(for: result)
        annotation = sidecar.map { ONTGenotypeIntegrityWarning.legacyLocusEdits(in: $0, calls: result.calls) } ?? []
    }
}

extension GenotypeResultDisplaySectionViewModel {
    /// The candidate warning lines of the full-length candidate section, the
    /// lead sentences and then each warning's plain line.
    public var mhcCandidateIntegrityWarnings: [String] {
        integrityWarningState.candidateLead
            + integrityWarningState.candidate.map(GenotypeResultIntegrityWarningList.line(for:))
    }

    /// The lead sentences of the candidate section's warnings.
    var mhcCandidateLeadWarnings: [String] { integrityWarningState.candidateLead }

    /// The candidate section's warnings, each shown with its code as help.
    var mhcCandidateCodedWarnings: [ONTGenotypeIntegrityWarning] { integrityWarningState.candidate }

    /// Integrity warnings that hold for every bundle type, such as the
    /// duplicate-row warning (D5b), then the annotation warnings, such as
    /// analyst edits saved at an old per-reference locus (N9). The Genotype
    /// Display section shows them under its row summary.
    public var resultIntegrityWarnings: [ONTGenotypeIntegrityWarning] {
        integrityWarningState.result + integrityWarningState.annotation
    }

    /// Reads the annotation sidecar against the result again, after the
    /// sidecar changed.
    public func updateAnnotationIntegrityWarnings(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar
    ) {
        integrityWarningState.annotation = ONTGenotypeIntegrityWarning.legacyLocusEdits(in: sidecar, calls: result.calls)
    }

    /// The Inspector's candidate warnings for a result (D3). Only a
    /// full-length result has them. When the bundle declares candidate
    /// artifacts that the loader rejected, the plain sentence of the shared
    /// basis rule leads, because locus percents and haplotype calls then
    /// count known alleles only and can differ from the run's own workbook.
    /// The warnings that name each failed file follow it. The duplicate-row
    /// warning is not a candidate warning, so it shows with
    /// `resultWarnings` instead.
    nonisolated static func candidateWarnings(
        for result: ONTGenotypeResultBundleData
    ) -> (lead: [String], warnings: [ONTGenotypeIntegrityWarning]) {
        guard result.manifest.kind == GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue else {
            return ([], [])
        }
        let lead = GenotypeLocusDenominator.basis(for: result) == .knownAllelesOnlyAfterRejectedCandidateArtifacts
            ? [GenotypeLocusDenominator.rejectedCandidateArtifactsDisclosure]
            : []
        return (lead, result.integrityWarnings.filter { !isResultWarning($0) })
    }

    /// The Inspector's warnings that hold for every bundle type (D5b).
    /// Duplicate rows for one animal, locus and allele collapse to one
    /// occurrence in amplicon, barcode and full-length bundles alike, so the
    /// Genotype Display section shows the warning outside the full-length
    /// candidate section.
    nonisolated static func resultWarnings(for result: ONTGenotypeResultBundleData) -> [ONTGenotypeIntegrityWarning] {
        result.integrityWarnings.filter(isResultWarning)
    }

    nonisolated private static func isResultWarning(_ warning: ONTGenotypeIntegrityWarning) -> Bool {
        warning.code == .duplicateCallRowsCollapsed
    }
}
