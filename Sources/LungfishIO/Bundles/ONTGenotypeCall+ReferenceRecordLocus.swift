import Foundation

// MARK: N9, a full-length call takes its source locus from its reference record

/// Stamps each full-length call with the source locus its reference record
/// names (N9).
///
/// A full-length ONT MHC call carries its reference sequence ID as the
/// genotype, for example the IPD accession NHP01270. Parsed alone, that name
/// is its own pseudo-locus (MHC-NHP01270), so every call read 100% of its
/// locus and every accession became its own locus column. The result's
/// reference record names the allele ("Mafa-A2*05:25:01:01") and the gene
/// ("A2"), and `GenotypeHaplotypeLocusResolver.referenceRecordLocus` turns
/// either into the locus key every other call uses (MHC-A).
///
/// `ONTGenotypeResultBundleData` applies this in its designated initializer,
/// before it collapses duplicate rows, so the loader, a decoded result, a GUI
/// rebuild and the pipeline's own workbook all read the same loci. A call is
/// stamped only when the result is a full-length result, the genotype has no
/// `source_loci` metadata, its record resolves a locus and that locus differs
/// from the one the genotype names. Amplicon results are never stamped.
struct ONTGenotypeReferenceRecordLocusStamp {
    /// The calls of the result, stamped where a record resolves a locus.
    private(set) var calls: [ONTGenotypeCall]
    /// The per-sample results, with their calls stamped the same way.
    private(set) var samples: [ONTGenotypeSampleResult]
    /// Plain-words warnings for unresolved or conflicting records.
    private(set) var warnings: [ONTGenotypeIntegrityWarning] = []

    /// The stamped calls with duplicate rows collapsed (D5b). The stamp
    /// comes before the collapse and before any value keyed on the locus.
    var uniqueCalls: [ONTGenotypeCall] { ONTGenotypeCall.uniqueOccurrences(calls) }
    /// The stamped per-sample results with duplicate rows collapsed.
    var collapsedSamples: [ONTGenotypeSampleResult] { samples.map { $0.collapsingDuplicateOccurrences() } }

    /// How many accessions a warning lists before it stops naming them.
    static let listedAccessionLimit = 5

    init(
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        manifest: ONTGenotypeResultBundleManifest,
        referenceMetadata: ONTGenotypeReferenceMetadata?
    ) {
        self.calls = calls
        self.samples = samples
        guard manifest.kind == GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue else { return }

        let records = referenceMetadata?.recordsBySequenceName ?? [:]
        let alleleFieldKey = referenceMetadata?.alleleFieldKey
        var resolutions: [String: Resolution] = [:]
        func resolution(for genotype: String) -> Resolution {
            if let known = resolutions[genotype] { return known }
            let resolved = Self.resolve(genotype: genotype, record: records[genotype], alleleFieldKey: alleleFieldKey)
            resolutions[genotype] = resolved
            return resolved
        }
        func stamped(_ call: ONTGenotypeCall) -> ONTGenotypeCall {
            guard case let .stamp(locus, _) = resolution(for: call.genotype) else { return call }
            return call.withSourceLocus(locus)
        }

        self.calls = calls.map(stamped)
        self.samples = samples.map { sample in
            let stampedCalls = sample.calls.map(stamped)
            guard stampedCalls != sample.calls else { return sample }
            return ONTGenotypeSampleResult(
                sample: sample.sample,
                passedAlignments: sample.passedAlignments,
                passedUniqueReads: sample.passedUniqueReads,
                sampleTotalReads: sample.sampleTotalReads,
                sampleUniqueRetainedPercent: sample.sampleUniqueRetainedPercent,
                calls: stampedCalls
            )
        }

        var unresolvedCalls = 0
        var unresolvedAccessions = Set<String>()
        var conflictingAccessions = Set<String>()
        // A duplicate row is one call (D5b), so count after the collapse.
        for call in ONTGenotypeCall.uniqueOccurrences(calls) {
            switch resolution(for: call.genotype) {
            case .unresolved where call.sourceLocus == nil:
                unresolvedCalls += 1
                unresolvedAccessions.insert(call.genotype)
            case .stamp(_, conflict: true):
                conflictingAccessions.insert(call.genotype)
            default:
                break
            }
        }
        if unresolvedCalls > 0 {
            warnings.append(Self.unresolvedWarning(
                callCount: unresolvedCalls, accessions: unresolvedAccessions, hasRecords: !records.isEmpty))
        }
        if !conflictingAccessions.isEmpty {
            warnings.append(Self.conflictWarning(accessions: conflictingAccessions))
        }
    }

    enum Resolution: Equatable {
        /// The genotype keeps the locus its name gives.
        case keep
        /// An accession-shaped genotype whose record names no locus. It keeps
        /// the locus its name gives, and the result warns.
        case unresolved
        /// The record's locus. `conflict` is true when the allele prefix and
        /// the gene name different loci, and the allele's locus was taken.
        case stamp(String, conflict: Bool)
    }

    static func resolve(genotype: String, record: [String: String]?, alleleFieldKey: String?) -> Resolution {
        guard MHCReferenceGenotypeDisplay.sourceLocus(for: genotype) == nil,
              GenotypeHaplotypeLocusResolver.metadataSourceLocus(for: genotype) == nil else { return .keep }
        let alleleLocus = GenotypeHaplotypeLocusResolver.referenceRecordAlleleLocus(
            record?[alleleFieldKey ?? GenotypeHaplotypeLocusResolver.referenceRecordDefaultAlleleFieldKey]
        )
        let geneLocus = GenotypeHaplotypeLocusResolver.referenceRecordGeneLocus(
            record?[GenotypeHaplotypeLocusResolver.referenceRecordGeneFieldKey]
        )
        guard let locus = alleleLocus ?? geneLocus else {
            return isAccessionShaped(genotype) ? .unresolved : .keep
        }
        let genotypeLocus = ONTGenotypeCall(
            sample: "", genotype: genotype, passedAlignments: 0, passedUniqueReads: 0,
            sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        ).genotypeLocusGroup
        guard locus != genotypeLocus else { return .keep }
        let conflict = alleleLocus != nil && geneLocus != nil && alleleLocus != geneLocus
        return .stamp(locus, conflict: conflict)
    }

    /// A sequence ID such as NHP01270, AB123456.1 or the RefSeq-style
    /// NM_001234.1, letters, an optional underscore, then at least four
    /// digits and an optional version. Such a name says nothing about its
    /// locus, so a missing record is worth a warning. An allele name carries
    /// its locus and needs no record.
    static func isAccessionShaped(_ genotype: String) -> Bool {
        let name = genotype.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let unversioned = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let stem = unversioned.first, !stem.isEmpty else { return false }
        if unversioned.count == 2 {
            let version = unversioned[1]
            guard !version.isEmpty, version.allSatisfy(\.isASCIIDigitCharacter) else { return false }
        }
        let letters = stem.prefix(while: \.isASCIILetterCharacter)
        var digits = stem.dropFirst(letters.count)
        if digits.first == "_" { digits = digits.dropFirst() }
        return (1...6).contains(letters.count) && digits.count >= 4 && digits.allSatisfy(\.isASCIIDigitCharacter)
    }

    /// The result's warnings with this stamp's warnings in place of any the
    /// warnings already carry. A decoded result passes in the warnings it
    /// was encoded with, so the stamp's warnings would otherwise appear
    /// twice and a round trip would not compare equal.
    func merging(_ resultWarnings: [ONTGenotypeIntegrityWarning]) -> [ONTGenotypeIntegrityWarning] {
        let stampCodes: Set<ONTGenotypeIntegrityWarningCode> = [.referenceLocusUnresolved, .referenceLocusConflict]
        return resultWarnings.filter { !stampCodes.contains($0.code) } + warnings
    }

    static func unresolvedWarning(
        callCount: Int, accessions: Set<String>, hasRecords: Bool
    ) -> ONTGenotypeIntegrityWarning {
        let calls = callCount == 1 ? "1 full-length call names" : "\(callCount) full-length calls name"
        let sequence = hasRecords ? "whose record gives no allele or gene" : "that has no reference record"
        let ownLocus = callCount == 1
            ? "This call is its own locus, so its percent of locus is always 100."
            : "Each of these calls is its own locus, so its percent of locus is always 100."
        let fix = !hasRecords
            ? "This result has no reference records. Run the genotyping again to add them."
            : accessions.count == 1
                ? "Check that the reference bundle carries a GenBank record for this sequence."
                : "Check that the reference bundle carries a GenBank record for each sequence."
        return ONTGenotypeIntegrityWarning(
            code: .referenceLocusUnresolved,
            detail: "\(calls) a reference sequence \(sequence) (\(listed(accessions))). \(ownLocus) \(fix)"
        )
    }

    static func conflictWarning(accessions: Set<String>) -> ONTGenotypeIntegrityWarning {
        let one = accessions.count == 1
        let records = one ? "1 reference record names" : "\(accessions.count) reference records name"
        let calls = one ? "Its calls use" : "Their calls use"
        let check = one ? "Check this record in the reference bundle." : "Check these records in the reference bundle."
        return ONTGenotypeIntegrityWarning(
            code: .referenceLocusConflict,
            detail: "\(records) an allele and a gene at different loci (\(listed(accessions))). "
                + "\(calls) the locus of the allele name. \(check)"
        )
    }

    private static func listed(_ accessions: Set<String>) -> String {
        let sorted = accessions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shown = sorted.prefix(listedAccessionLimit).joined(separator: ", ")
        let hidden = sorted.count - min(sorted.count, listedAccessionLimit)
        return hidden > 0 ? "\(shown) and \(hidden) more" : shown
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
    var isASCIILetterCharacter: Bool { isASCII && isLetter }
}
