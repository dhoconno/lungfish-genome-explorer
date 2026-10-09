import Foundation
import LungfishIO

extension GenotypeResultDisplaySectionViewModel {
    /// The Inspector's candidate warning lines for a result (D3). Only a
    /// full-length result has them. When the bundle declares candidate
    /// artifacts that the loader rejected, the plain sentence of the shared
    /// basis rule leads, because locus percents and haplotype calls then
    /// count known alleles only and can differ from the run's own workbook.
    /// The coded lines that name each failed file follow it.
    static func candidateWarningLines(for result: ONTGenotypeResultBundleData) -> [String] {
        guard result.manifest.kind == GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue else {
            return []
        }
        let lead = GenotypeLocusDenominator.basis(for: result) == .knownAllelesOnlyAfterRejectedCandidateArtifacts
            ? [GenotypeLocusDenominator.rejectedCandidateArtifactsDisclosure]
            : []
        return lead + result.integrityWarnings.map(integrityWarningText)
    }

    /// One coded warning line, the code, the detail and the file it names.
    static func integrityWarningText(_ warning: ONTGenotypeIntegrityWarning) -> String {
        let location = warning.path.map { " (\($0))" } ?? ""
        return "\(warning.code.rawValue): \(warning.detail)\(location)"
    }
}
