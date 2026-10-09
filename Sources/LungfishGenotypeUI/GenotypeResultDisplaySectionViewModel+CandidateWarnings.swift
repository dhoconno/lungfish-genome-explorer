import Foundation
import LungfishIO

extension GenotypeResultDisplaySectionViewModel {
    /// The candidate warning lines of the full-length candidate section.
    public var mhcCandidateIntegrityWarnings: [String] { integrityWarningLines.candidate }

    /// Integrity warnings that hold for every bundle type, such as the
    /// duplicate-row warning (D5b). The Genotype Display section shows them
    /// under its row summary.
    public var resultIntegrityWarnings: [String] { integrityWarningLines.result }

    /// The Inspector's candidate warning lines for a result (D3). Only a
    /// full-length result has them. When the bundle declares candidate
    /// artifacts that the loader rejected, the plain sentence of the shared
    /// basis rule leads, because locus percents and haplotype calls then
    /// count known alleles only and can differ from the run's own workbook.
    /// The coded lines that name each failed file follow it. The
    /// duplicate-row warning is not a candidate warning, so it shows with
    /// `resultWarningLines` instead.
    static func candidateWarningLines(for result: ONTGenotypeResultBundleData) -> [String] {
        guard result.manifest.kind == GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue else {
            return []
        }
        let lead = GenotypeLocusDenominator.basis(for: result) == .knownAllelesOnlyAfterRejectedCandidateArtifacts
            ? [GenotypeLocusDenominator.rejectedCandidateArtifactsDisclosure]
            : []
        return lead + result.integrityWarnings
            .filter { !isResultWarning($0) }
            .map(integrityWarningText)
    }

    /// The Inspector's warning lines that hold for every bundle type (D5b).
    /// Duplicate rows for one animal, locus and allele collapse to one
    /// occurrence in amplicon, barcode and full-length bundles alike, so the
    /// Genotype Display section shows the warning outside the full-length
    /// candidate section, in the same coded line.
    static func resultWarningLines(for result: ONTGenotypeResultBundleData) -> [String] {
        result.integrityWarnings.filter(isResultWarning).map(integrityWarningText)
    }

    private static func isResultWarning(_ warning: ONTGenotypeIntegrityWarning) -> Bool {
        warning.code == .duplicateCallRowsCollapsed
    }

    /// One coded warning line, the code, the detail and the file it names.
    static func integrityWarningText(_ warning: ONTGenotypeIntegrityWarning) -> String {
        let location = warning.path.map { " (\($0))" } ?? ""
        return "\(warning.code.rawValue): \(warning.detail)\(location)"
    }
}
