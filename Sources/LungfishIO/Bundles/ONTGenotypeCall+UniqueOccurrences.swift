import Foundation

// MARK: D5b, one occurrence per animal, locus and allele

extension ONTGenotypeCall {
    /// One occurrence per animal, locus and allele (D5b).
    ///
    /// Two rows for one animal and one allele are a data error. The current
    /// pipelines write one row per animal and reference, and the catalog
    /// publisher refuses duplicates, so such rows come only from edited or
    /// concatenated long-summary tables. Almost always the same observation
    /// was written twice, so the rows are never summed. The row with the most
    /// passed unique reads is kept, then the most alignments, then the first
    /// in file order. The kept row takes the position of the first row of
    /// its animal and allele, so file order is preserved. The bundle loader
    /// and the `ONTGenotypeResultBundleData` initializer both apply this
    /// rule, so every surface that reads a result's calls sees one value per
    /// cell and every total counts it once.
    public static func uniqueOccurrences(_ calls: [ONTGenotypeCall]) -> [ONTGenotypeCall] {
        var kept: [ONTGenotypeCall] = []
        kept.reserveCapacity(calls.count)
        var positions: [Occurrence: Int] = [:]
        for call in calls {
            let occurrence = Occurrence(sample: call.sample, genotype: call.genotype)
            if let position = positions[occurrence] {
                if call.outranksDuplicate(kept[position]) {
                    kept[position] = call
                }
            } else {
                positions[occurrence] = kept.count
                kept.append(call)
            }
        }
        return kept
    }

    /// Whether this row replaces an earlier row of the same animal and
    /// allele. More passed unique reads win, then more alignments. An exact
    /// tie keeps the earlier row.
    private func outranksDuplicate(_ earlier: ONTGenotypeCall) -> Bool {
        if passedUniqueReads != earlier.passedUniqueReads {
            return passedUniqueReads > earlier.passedUniqueReads
        }
        return passedAlignments > earlier.passedAlignments
    }

    /// The identity of one occurrence. The locus is a function of the
    /// genotype, so the animal and the genotype name it.
    private struct Occurrence: Hashable {
        let sample: String
        let genotype: String
    }
}

extension ONTGenotypeSampleResult {
    /// The same sample result with its calls collapsed to one occurrence per
    /// allele (D5b). The sample's own read counts come from the sample
    /// summary and stay as written.
    public func collapsingDuplicateOccurrences() -> ONTGenotypeSampleResult {
        let unique = ONTGenotypeCall.uniqueOccurrences(calls)
        guard unique.count != calls.count else { return self }
        return ONTGenotypeSampleResult(
            sample: sample,
            passedAlignments: passedAlignments,
            passedUniqueReads: passedUniqueReads,
            sampleTotalReads: sampleTotalReads,
            sampleUniqueRetainedPercent: sampleUniqueRetainedPercent,
            calls: unique
        )
    }
}

extension ONTGenotypeIntegrityWarning {
    /// The warning that names how many duplicate rows
    /// `ONTGenotypeCall.uniqueOccurrences` collapsed, from the row count
    /// before and after. Empty when nothing was collapsed, so a result
    /// without duplicates carries no warning and re-encodes byte for byte.
    public static func duplicateCallRowsCollapsed(rowCount: Int, uniqueCount: Int) -> [ONTGenotypeIntegrityWarning] {
        let collapsed = rowCount - uniqueCount
        guard collapsed > 0 else { return [] }
        let rows = collapsed == 1 ? "1 duplicate genotype row was" : "\(collapsed) duplicate genotype rows were"
        return [
            ONTGenotypeIntegrityWarning(
                code: .duplicateCallRowsCollapsed,
                detail: "\(rows) collapsed. The long summary listed one animal, locus and allele more than once, "
                    + "and the row with the most passed unique reads was kept. Check the sample sheet and the long summary."
            ),
        ]
    }
}
