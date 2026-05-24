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
        sidecar: GenotypeAnnotationSidecar,
        metadataBySample: [String: [String: String]] = [:]
    ) -> [GenotypeCohortSubject] {
        let analysesBySample: [String: GenotypeHaplotypeSampleAnalysis] = Dictionary(
            uniqueKeysWithValues: (result.haplotypeAnalysis?.samples ?? []).map { ($0.sample, $0) }
        )
        let sampleResultsByName: [String: ONTGenotypeSampleResult] = Dictionary(
            uniqueKeysWithValues: result.samples.map { ($0.sample, $0) }
        )
        let rawCallsBySample = Dictionary(grouping: result.calls, by: \.sample)
        var seenSamples = Set<String>()
        let sampleIds = (result.sampleNames + result.samples.map(\.sample) + result.calls.map(\.sample))
            .filter { seenSamples.insert($0).inserted }
        let notesBySample = Dictionary(grouping: sidecar.sampleNotes, by: \.sample)
        let commentsBySample = Dictionary(grouping: sidecar.cellComments, by: \.sample)
        let highlightsBySample = Dictionary(grouping: sidecar.cellHighlights, by: \.sample)
        let statusBySample = Dictionary(uniqueKeysWithValues:
            sidecar.sampleStatusFlags.map { ($0.sample, $0.value) }
        )
        var overridesBySampleLocusSlot: [String: String] = [:]
        for override in sidecar.callOverrides {
            overridesBySampleLocusSlot[
                overrideKey(sample: override.sample, locus: override.locus, slot: override.slot)
            ] = override.overrideCall
        }

        return sampleIds.map { sample in
            let sampleResult = sampleResultsByName[sample]
            let analysis = analysesBySample[sample]
            let comments = (notesBySample[sample] ?? []).map(\.body)
                + (commentsBySample[sample] ?? []).map(\.body)
            let highlightFills = (highlightsBySample[sample] ?? [])
                .compactMap(\.fillColor)
            let highlightBorders = (highlightsBySample[sample] ?? [])
                .compactMap(\.borderColor)
            let effectiveCalls = (analysis?.calls ?? []).map { locusCall in
                let h1 = overridesBySampleLocusSlot[
                    overrideKey(sample: sample, locus: locusCall.locus, slot: .h1)
                ] ?? locusCall.haplotype1
                let h2 = overridesBySampleLocusSlot[
                    overrideKey(sample: sample, locus: locusCall.locus, slot: .h2)
                ] ?? locusCall.haplotype2
                let hasOverride = h1 != locusCall.haplotype1 || h2 != locusCall.haplotype2
                let isError = (locusCall.status != .called
                    && locusCall.status != .notAssayed
                    && locusCall.status != .specialCase
                    && !hasOverride)
                    || h1.hasPrefix("ERR:")
                    || h2.hasPrefix("ERR:")
                return (
                    locus: locusCall.locus,
                    h1: h1,
                    h2: h2,
                    status: locusCall.status,
                    isError: isError
                )
            }
            let calls: [GenotypeCohortSubject.Call] = effectiveCalls.flatMap { locusCall in
                let isNotAssayed = locusCall.status == .notAssayed
                let isHomozygous = !isNotAssayed && locusCall.h1 == locusCall.h2
                return [
                    GenotypeCohortSubject.Call(
                        locus: locusCall.locus,
                        slot: .h1,
                        name: locusCall.h1,
                        isHomozygous: isHomozygous,
                        isError: locusCall.isError,
                        isRecombinant: locusCall.h1.hasPrefix("rec") || locusCall.h2.hasPrefix("rec"),
                        readCount: 0
                    ),
                    GenotypeCohortSubject.Call(
                        locus: locusCall.locus,
                        slot: .h2,
                        name: locusCall.h2,
                        isHomozygous: isHomozygous,
                        isError: locusCall.isError,
                        isRecombinant: locusCall.h1.hasPrefix("rec") || locusCall.h2.hasPrefix("rec"),
                        readCount: 0
                    ),
                ]
            }
            let hasErrorAtAnyLocus = effectiveCalls.contains { $0.isError }
            // "Homozygous across all" means every CALLED locus is either
            // explicitly homozygous (haplotype1 == haplotype2) OR shows
            // a single matched haplotype (h2 == "-", which the analyzer
            // emits when only one haplotype's diagnostic set was
            // observed). Not-assayed rows are neutral: they don't create
            // errors, and they also don't count as homozygous evidence.
            let calledLocusCalls = effectiveCalls.filter {
                !$0.isError && $0.status != .notAssayed
            }
            let isHomozygousAcrossAll = !hasErrorAtAnyLocus && !calledLocusCalls.isEmpty &&
                calledLocusCalls.allSatisfy { call in
                    guard !call.h1.hasPrefix("ERR") else { return false }
                    // Single-match (h2 = "-") counts as homozygous since
                    // the analyzer found only one haplotype's diagnostic
                    // alleles in the sample.
                    if call.h2 == "-" || call.h2.isEmpty { return true }
                    return call.h1 == call.h2
                }
            let hasRegionalRecombinant = effectiveCalls.contains { call in
                call.h1.hasPrefix("rec") || call.h2.hasPrefix("rec")
            }
            let blockKind = GenotypeBlockClassifier.classify(
                calls: effectiveCalls.map {
                    (locus: $0.locus, h1: $0.h1, h2: $0.h2)
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
                metadata: metadataBySample[sample] ?? [:],
                rawGenotypes: (rawCallsBySample[sample] ?? []).flatMap { [$0.genotype, $0.locusGroup] },
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

    private static func overrideKey(sample: String, locus: String, slot: HaplotypeSlot) -> String {
        "\(sample)\u{1F}\(locus)\u{1F}\(slot.rawValue)"
    }
}
