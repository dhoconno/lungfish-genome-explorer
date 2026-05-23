import Foundation
import LungfishCore

/// Builds `GenotypeCohortSubject` values from a bundle's result + sidecar.
///
/// The smart cohort evaluator runs over these subjects to compute cohort
/// counts in the Inspector and to filter the cohort list in the viewport.
/// The same builder is used by the CLI's `list-cohorts` subcommand so that
/// counts surfaced headlessly match what an analyst sees in the GUI.
public enum GenotypeCohortSubjectBuilder {
    public static func buildSubjects(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar
    ) -> [GenotypeCohortSubject] {
        let analysesBySample: [String: GenotypeHaplotypeSampleAnalysis] = Dictionary(
            uniqueKeysWithValues: (result.haplotypeAnalysis?.samples ?? []).map { ($0.sample, $0) }
        )
        let sampleResultsByName: [String: ONTGenotypeSampleResult] = Dictionary(
            uniqueKeysWithValues: result.samples.map { ($0.sample, $0) }
        )
        let sampleIds = !result.sampleNames.isEmpty
            ? result.sampleNames
            : result.samples.map(\.sample)
        let notesBySample = Dictionary(grouping: sidecar.sampleNotes, by: \.sample)
        let commentsBySample = Dictionary(grouping: sidecar.cellComments, by: \.sample)
        let highlightsBySample = Dictionary(grouping: sidecar.cellHighlights, by: \.sample)
        let statusBySample = Dictionary(uniqueKeysWithValues:
            sidecar.sampleStatusFlags.map { ($0.sample, $0.value) }
        )

        return sampleIds.map { sample in
            let sampleResult = sampleResultsByName[sample]
            let analysis = analysesBySample[sample]
            let comments = (notesBySample[sample] ?? []).map(\.body)
                + (commentsBySample[sample] ?? []).map(\.body)
            let highlightFills = (highlightsBySample[sample] ?? [])
                .compactMap(\.fillColor)
            let highlightBorders = (highlightsBySample[sample] ?? [])
                .compactMap(\.borderColor)
            let calls: [GenotypeCohortSubject.Call] = (analysis?.calls ?? []).flatMap { locusCall in
                [
                    GenotypeCohortSubject.Call(
                        locus: locusCall.locus,
                        slot: .h1,
                        name: locusCall.haplotype1,
                        isHomozygous: locusCall.haplotype1 == locusCall.haplotype2,
                        isError: locusCall.status != .called && locusCall.status != .specialCase,
                        isRecombinant: locusCall.haplotype1.hasPrefix("rec") || locusCall.haplotype2.hasPrefix("rec"),
                        readCount: 0
                    ),
                    GenotypeCohortSubject.Call(
                        locus: locusCall.locus,
                        slot: .h2,
                        name: locusCall.haplotype2,
                        isHomozygous: locusCall.haplotype1 == locusCall.haplotype2,
                        isError: locusCall.status != .called && locusCall.status != .specialCase,
                        isRecombinant: locusCall.haplotype1.hasPrefix("rec") || locusCall.haplotype2.hasPrefix("rec"),
                        readCount: 0
                    ),
                ]
            }
            let hasErrorAtAnyLocus = (analysis?.calls ?? []).contains { call in
                call.status != .called && call.status != .specialCase
            }
            // "Homozygous across all" means every CALLED locus is either
            // explicitly homozygous (haplotype1 == haplotype2) OR shows
            // a single matched haplotype (h2 == "-", which the analyzer
            // emits when only one haplotype's diagnostic set was
            // observed). Error rows are excluded so samples with all-
            // error calls don't falsely match.
            let calledLocusCalls = (analysis?.calls ?? []).filter {
                $0.status == .called || $0.status == .specialCase
            }
            let isHomozygousAcrossAll = !calledLocusCalls.isEmpty &&
                calledLocusCalls.allSatisfy { call in
                    guard !call.haplotype1.hasPrefix("ERR") else { return false }
                    // Single-match (h2 = "-") counts as homozygous since
                    // the analyzer found only one haplotype's diagnostic
                    // alleles in the sample.
                    if call.haplotype2 == "-" || call.haplotype2.isEmpty { return true }
                    return call.haplotype1 == call.haplotype2
                }
            let hasRegionalRecombinant = (analysis?.calls ?? []).contains { call in
                call.haplotype1.hasPrefix("rec") || call.haplotype2.hasPrefix("rec")
            }
            let blockKind = GenotypeBlockClassifier.classify(
                calls: (analysis?.calls ?? []).map {
                    (locus: $0.locus, h1: $0.haplotype1, h2: $0.haplotype2)
                }
            )
            let hasAtypicalPattern = blockKind == .atypical

            // The bundle's per-sample identifier is the GS ID (DW472 etc.).
            // The animal ID is normally surfaced through the imported
            // metadata store; in absence of that store, animalId == gsId.
            return GenotypeCohortSubject(
                animalId: sample,
                gsId: sample,
                qcStatus: sampleResult?.qcStatus ?? .review,
                totalReads: sampleResult?.sampleTotalReads ?? 0,
                // unmappedPercent is the % of input reads that did not map
                // to any reference; the bundle's stats JSON exposes it at
                // the run level only. Predicates that filter on this field
                // therefore match no subjects today; surface it once the
                // sample-summary CSV is parsed.
                unmappedPercent: 0,
                comments: comments.joined(separator: " · "),
                calls: calls,
                hasAnyComment: !comments.isEmpty,
                hasErrorAtAnyLocus: hasErrorAtAnyLocus,
                isHomozygousAcrossAll: isHomozygousAcrossAll,
                hasRegionalRecombinant: hasRegionalRecombinant,
                hasAtypicalPattern: hasAtypicalPattern,
                statusValue: statusBySample[sample] ?? .unflagged,
                highlightFills: highlightFills,
                highlightBorders: highlightBorders
            )
        }
    }
}
