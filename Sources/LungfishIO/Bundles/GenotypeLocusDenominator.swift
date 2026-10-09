import Foundation

/// The one read denominator behind every "percent of locus"
/// number.
///
/// A locus percentage is an allele's unique retained reads divided by the
/// unique retained reads of the same sample at the same **source locus**
/// (`source_loci` metadata when the reference carries it, otherwise the
/// locus parsed from the allele name). Haplotype groups are never pooled:
/// MHC-G, MHC-AG and MHC-E are each normalized on their own even when the
/// reference files them all under `haplotype_groups=MHC-A`, because source
/// loci can differ in depth by orders of magnitude.
///
/// The genotype matrix, the haplotype evidence pane, the haplotype caller's
/// dropout filter and the Excel filter all read this type, so the same allele
/// shows the same percentage everywhere.
public struct GenotypeLocusDenominator: Sendable, Equatable {
    /// Short basis label for threshold controls, workbooks and provenance.
    public static let basisLabel = "per source locus"
    /// One-sentence basis statement for workbooks and provenance.
    public static let basisDescription =
        "Unique retained reads of the same sample at the same source locus "
        + "(known alleles plus candidate clusters at that locus)"

    public struct Key: Hashable, Sendable {
        public let sample: String
        public let sourceLocus: String

        public init(sample: String, sourceLocus: String) {
            self.sample = GenotypeLocusDenominator.normalizedSample(sample)
            self.sourceLocus = GenotypeLocusDenominator.sourceLocus(forLocusLabel: sourceLocus)
        }
    }

    private let totals: [Key: Int]

    /// Builds the denominators from known calls and, when present, the reads
    /// of candidate clusters (novel alleles and interpreted incomplete
    /// clusters) observed at the same source locus. Known calls enter through
    /// `knownReadTotals(calls:)`, so a tied cluster counts once (D2).
    public init(
        calls: [ONTGenotypeCall],
        candidateDocument: ONTMHCCandidateAllelesDocument? = nil,
        unnameableDocument: ONTMHCUnnameableClustersDocument? = nil
    ) {
        var totals = Self.knownReadTotals(calls: calls)
        if let candidateDocument {
            let locusByCluster = Dictionary(
                candidateDocument.candidates.map { ($0.stableClusterID, $0.locus) },
                uniquingKeysWith: { first, _ in first }
            )
            for observation in candidateDocument.observations {
                guard let locus = locusByCluster[observation.stableClusterID] else { continue }
                totals[Key(sample: observation.sampleID, sourceLocus: locus), default: 0]
                    += max(0, observation.aggregatedSampleReadCount)
            }
        }
        if let unnameableDocument {
            let locusByCluster = Dictionary(
                unnameableDocument.clusters.compactMap { record in
                    record.candidateInterpretation.map { (record.stableClusterID, $0.locus) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            for observation in unnameableDocument.observations {
                guard let locus = locusByCluster[observation.stableClusterID] else { continue }
                totals[Key(sample: observation.sampleID, sourceLocus: locus), default: 0]
                    += max(0, observation.aggregatedSampleReadCount)
            }
        }
        self.totals = totals
    }

    public init(result: ONTGenotypeResultBundleData) {
        self.init(
            calls: result.calls,
            candidateDocument: result.mhcCandidates,
            unnameableDocument: result.mhcUnnameableClusters
        )
    }

    // MARK: D2, a tied cluster counts once

    /// The known reads of every sample at every source locus, counting a
    /// tied cluster once (D2).
    ///
    /// A full-length result gives each equal-best reference of a cluster its
    /// own call with the full cluster reads and the tie list in
    /// `ambiguousWith`, so summing calls counts a k-way tie k times. Within
    /// one animal and one source locus, calls that name each other in
    /// `ambiguousWith` and carry the same passed unique reads describe one
    /// cluster whose reads fit each tied reference equally, and they count
    /// once. Calls with different reads are summed as before, which errs high
    /// and never below the true total. Each tied reference keeps its full
    /// reads as its own support, with no split and no merged call.
    ///
    /// An amplicon row whose `ambiguousWith` names references collapsed before
    /// mapping is the only call of its group, so its total is unchanged, and a
    /// tie whose members parse to two loci counts once at each locus. This is
    /// the one rule behind the locus denominator, the haplotype analyzer's
    /// sample totals and the observed-loci read totals.
    public static func knownReadTotals(calls: [ONTGenotypeCall]) -> [Key: Int] {
        var totals: [Key: Int] = [:]
        totals.reserveCapacity(calls.count)
        var countedTies = Set<TieGroup>()
        for call in calls {
            let key = Key(sample: call.sample, sourceLocus: call.locusGroup)
            let reads = max(0, call.passedUniqueReads)
            if let members = call.ambiguousWith {
                let tie = TieGroup(key: key, members: Set(members).union([call.genotype]), reads: reads)
                guard countedTies.insert(tie).inserted else { continue }
            }
            totals[key, default: 0] += reads
        }
        return totals
    }

    /// The known reads of every normalized sample across its source loci,
    /// counting a tied cluster once. The haplotype analyzer's sample fraction
    /// divides by this total.
    public static func sampleTotals(calls: [ONTGenotypeCall]) -> [String: Int] {
        knownReadTotals(calls: calls).reduce(into: [:]) { totals, entry in
            totals[entry.key.sample, default: 0] += entry.value
        }
    }

    /// One tied cluster of one animal at one source locus.
    private struct TieGroup: Hashable {
        let key: Key
        let members: Set<String>
        let reads: Int
    }

    // MARK: D3, the basis a result's locus totals count

    /// What a result's locus totals count (D3).
    public enum Basis: String, Equatable, Sendable {
        /// Known alleles plus the candidate clusters observed at the locus,
        /// the documented basis.
        case knownAllelesAndCandidateClusters
        /// Known alleles only. The bundle declares candidate artifacts that
        /// the loader rejected, so no candidate reads could be counted, and
        /// locus percents and haplotype calls can differ from the run's own
        /// workbook.
        case knownAllelesOnlyAfterRejectedCandidateArtifacts
    }

    /// The basis of a result's locus totals. A full-length bundle whose
    /// manifest declares a candidate or un-nameable document while neither
    /// loaded has had its candidate artifacts rejected by the loader's
    /// all-or-nothing validation. Any other result counts candidate clusters
    /// wherever it has them. The workbook's Percent basis row, the
    /// Inspector's candidate warning and the CLI exports all read this one
    /// value.
    public static func basis(for result: ONTGenotypeResultBundleData) -> Basis {
        guard result.manifest.kind == GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
              let declared = result.manifest.mhcCandidateArtifacts,
              declared.candidateJSON != nil || declared.unnameableJSON != nil,
              result.mhcCandidates == nil, result.mhcUnnameableClusters == nil else {
            return .knownAllelesAndCandidateClusters
        }
        return .knownAllelesOnlyAfterRejectedCandidateArtifacts
    }

    /// The one-sentence basis statement for a basis. Normal bundles keep
    /// `basisDescription` byte for byte.
    public static func basisDescription(for basis: Basis) -> String {
        switch basis {
        case .knownAllelesAndCandidateClusters: return basisDescription
        case .knownAllelesOnlyAfterRejectedCandidateArtifacts: return knownAllelesOnlyBasisDescription
        }
    }

    /// The basis statement of a bundle whose candidate artifacts failed
    /// validation.
    public static let knownAllelesOnlyBasisDescription =
        "Unique retained reads of the same sample at the same source locus "
        + "(known alleles only, because the bundle's candidate artifacts failed validation)"

    /// The plain-words disclosure for such a bundle, the lead sentence of the
    /// Inspector's candidate warning and the one line the CLI genotype
    /// exports print on standard error.
    public static let rejectedCandidateArtifactsDisclosure =
        "Candidate files failed validation, so candidate alleles are hidden and locus percents and "
        + "haplotype calls count known-allele reads only. These values can differ from the run's own workbook."

    /// The source-locus key for a call: `source_loci` metadata first, the
    /// allele name otherwise (the same key the matrix groups rows by).
    public static func sourceLocus(for call: ONTGenotypeCall) -> String {
        call.locusGroup
    }

    /// Canonical source-locus key for a raw locus label such as a candidate's
    /// `MHC-A1` or a call's `locusGroup`. Idempotent.
    public static func sourceLocus(forLocusLabel label: String) -> String {
        ONTGenotypeCall.sourceLocusGroup(forLocusToken: label)
    }

    public static func normalizedSample(_ sample: String) -> String {
        let cleaned = sample
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? sample : cleaned
    }

    public func total(sample: String, sourceLocus: String) -> Int {
        totals[Key(sample: sample, sourceLocus: sourceLocus)] ?? 0
    }

    public func total(for call: ONTGenotypeCall) -> Int {
        total(sample: call.sample, sourceLocus: call.locusGroup)
    }

    /// `reads / total`, or nil when the sample has no reads at that locus.
    public func fraction(reads: Int, sample: String, sourceLocus: String) -> Double? {
        let denominator = total(sample: sample, sourceLocus: sourceLocus)
        guard denominator > 0 else { return nil }
        return Double(reads) / Double(denominator)
    }

    public func fraction(for call: ONTGenotypeCall) -> Double? {
        fraction(reads: call.passedUniqueReads, sample: call.sample, sourceLocus: call.locusGroup)
    }
}
