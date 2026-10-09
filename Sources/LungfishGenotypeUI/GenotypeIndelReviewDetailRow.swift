import LungfishIO

/// The Inspector's Selected Item row for the indel review flag, shown beside
/// the tie partners. A full-length pipeline writes `review_flag` as "indel"
/// when the zero-SNP hit behind a known call carries inserted or deleted
/// bases, and as empty otherwise. The loader keeps the base count behind that
/// flag in `indelBases`, so `needsIndelReview` is the flag. The call stays a
/// known call, but nanopore errors and real indels look alike, so the row
/// asks the scientist to check the alignment.
enum GenotypeIndelReviewDetailRow {
    static let label = "Review flag"

    /// The tie partners row of `GenotypeSharedReadsDetailRow`, then the
    /// review flag row, for the selected cell of `genotype` in `sample`.
    static func rowsBesideSharedReads(
        genotype: String,
        sample: String?,
        callsBySample: [String: [ONTGenotypeCall]]
    ) -> [(String, String)] {
        GenotypeSharedReadsDetailRow.rows(genotype: genotype, sample: sample, callsBySample: callsBySample)
            + rows(genotype: genotype, sample: sample, callsBySample: callsBySample)
    }

    /// The row for the selected cell of `genotype` in `sample`, or nothing
    /// for a row selection, a call without indels, or an amplicon call.
    static func rows(
        genotype: String,
        sample: String?,
        callsBySample: [String: [ONTGenotypeCall]]
    ) -> [(String, String)] {
        guard let sample,
              let call = callsBySample[sample]?.first(where: { $0.genotype == genotype }),
              call.needsIndelReview,
              let indelBases = call.indelBases else {
            return []
        }
        return [(label, text(indelBases: indelBases))]
    }

    static func text(indelBases: Int) -> String {
        let bases = indelBases == 1 ? "1 inserted or deleted base" : "\(indelBases) inserted or deleted bases"
        return "Indel. The reads match this reference with \(bases), "
            + "so check the alignment before relying on this call."
    }
}
