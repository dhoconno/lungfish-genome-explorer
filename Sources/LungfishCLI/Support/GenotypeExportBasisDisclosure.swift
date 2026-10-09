import Foundation
import LungfishIO

/// Decision D3 of the Phase 2.3 follow-up. When a bundle declares candidate
/// artifacts that the loader rejected, its locus percents and haplotype calls
/// count known alleles only. Every genotype export (export, export-xlsx,
/// export-pivot-xlsx and export-labkey) says so once on standard error, in the
/// words `GenotypeLocusDenominator` owns, and says nothing for any other
/// bundle.
enum GenotypeExportBasisDisclosure {
    /// The line to print for a loaded result, nil when there is nothing to
    /// say.
    static func line(for result: ONTGenotypeResultBundleData?) -> String? {
        guard let result,
              GenotypeLocusDenominator.basis(for: result) == .knownAllelesOnlyAfterRejectedCandidateArtifacts else {
            return nil
        }
        return GenotypeLocusDenominator.rejectedCandidateArtifactsDisclosure
    }

    /// Prints the line on standard error when the result calls for it.
    static func disclose(_ result: ONTGenotypeResultBundleData?) {
        guard let line = line(for: result) else { return }
        printStatusLine(line)
    }
}
