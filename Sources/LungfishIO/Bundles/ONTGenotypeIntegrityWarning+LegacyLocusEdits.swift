import Foundation

// MARK: N9, analyst edits saved at an old per-reference locus

extension ONTGenotypeIntegrityWarning {
    /// The warning that counts the sidecar's call overrides, cell highlights,
    /// cell comments and call status flags saved at a stamped call's old
    /// per-reference pseudo-locus (MHC-NHP01270).
    ///
    /// These edits name a haplotype locus and a slot. Before N9 each
    /// full-length accession was its own locus, and now its call sits at the
    /// gene locus with the other alleles of that gene, so a saved slot cannot
    /// be mapped to one slot at the gene locus. The edits are left as saved,
    /// they no longer apply, and this warning says how many. Empty when the
    /// result has no stamped call or no edit names an old locus. The warning
    /// needs the sidecar, so it is not one of the result's own warnings.
    public static func legacyLocusEdits(
        in sidecar: GenotypeAnnotationSidecar,
        calls: [ONTGenotypeCall]
    ) -> [ONTGenotypeIntegrityWarning] {
        let canonical = GenotypeHaplotypeLocusResolver.canonicalLocusName
        let stamped = calls.filter { $0.sourceLocus != nil }
        let currentLoci = Set(calls.map { canonical($0.locusGroup) })
        let oldLoci = Set(stamped.map { canonical($0.genotypeLocusGroup) }).subtracting(currentLoci)
        guard !oldLoci.isEmpty else { return [] }
        let savedLoci = sidecar.callOverrides.map(\.locus)
            + sidecar.cellHighlights.map(\.locus)
            + sidecar.cellComments.map(\.locus)
            + sidecar.callStatusFlags.map(\.locus)
        let count = savedLoci.filter { oldLoci.contains(canonical($0)) }.count
        guard count > 0 else { return [] }
        let detail = count == 1
            ? "1 analyst edit was saved at an old per-reference locus and no longer applies. "
                + "Review it again at the gene locus."
            : "\(count) analyst edits were saved at an old per-reference locus and no longer apply. "
                + "Review them again at the gene locus."
        return [ONTGenotypeIntegrityWarning(code: .legacyLocusEditsOrphaned, detail: detail)]
    }
}
