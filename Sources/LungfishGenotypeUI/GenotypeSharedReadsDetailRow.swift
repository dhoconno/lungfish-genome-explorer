import LungfishIO

/// The Inspector's Selected Item row that names the partners a tied call
/// shares its reads with (D2). A full-length result gives each equal-best
/// reference of a cluster its own call with the full cluster reads, so two
/// tied rows read like a heterozygote until the row says otherwise.
enum GenotypeSharedReadsDetailRow {
    static let label = "Shares reads with"

    /// The row for the selected cell of `genotype` in `sample`, or nothing
    /// for a row selection, an ordinary call, or an amplicon group whose
    /// aliases are not calls of the animal.
    static func rows(
        genotype: String,
        sample: String?,
        callsBySample: [String: [ONTGenotypeCall]]
    ) -> [(String, String)] {
        guard let sample,
              let sampleCalls = callsBySample[sample],
              let call = sampleCalls.first(where: { $0.genotype == genotype }) else {
            return []
        }
        let partners = call.sharedReadPartners(in: sampleCalls)
        return partners.isEmpty ? [] : [(label, partners.joined(separator: ", "))]
    }
}
