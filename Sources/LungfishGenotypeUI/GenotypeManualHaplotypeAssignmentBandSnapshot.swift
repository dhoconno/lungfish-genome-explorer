import AppKit
import LungfishCore
import LungfishIO

@MainActor
struct GenotypeManualHaplotypeAssignmentBandSnapshot: Equatable {
    static let loci = GenotypeManualHaplotypeLocus.allCases

    let valuesBySample: [String: [String]]
    let tooltipsBySample: [String: [String]]
    let accessibilitySummaryBySample: [String: String]

    init(index: GenotypeManualHaplotypeAssignmentIndex, samples: [String]) {
        var valuesBySample: [String: [String]] = [:]
        var tooltipsBySample: [String: [String]] = [:]
        var summaries: [String: String] = [:]
        valuesBySample.reserveCapacity(samples.count)
        summaries.reserveCapacity(samples.count)

        for sample in samples {
            var summaryParts: [String] = []
            var sampleTooltips: [String] = []
            let values = Self.loci.map { locus -> String in
                let assignments = index.assignments(sample: sample, locus: locus)
                let h1 = assignments.h1?.label
                let h2 = assignments.h2?.label
                let locusSummary = [
                    h1.map { "H1 \($0)" },
                    h2.map { "H2 \($0)" },
                ].compactMap { $0 }
                if !locusSummary.isEmpty {
                    summaryParts.append(
                        "\(locus.workbookLabel) "
                            + locusSummary.joined(separator: ", ")
                    )
                }
                sampleTooltips.append(
                    "\(locus.workbookLabel) — H1: \(h1 ?? "unassigned"); "
                        + "H2: \(h2 ?? "unassigned")"
                )
                switch (h1, h2) {
                case (.none, .none): return "—"
                case let (.some(h1), .none): return "\(h1) · —"
                case let (.none, .some(h2)): return "— · \(h2)"
                case let (.some(h1), .some(h2)): return "\(h1) · \(h2)"
                }
            }
            valuesBySample[sample] = values
            tooltipsBySample[sample] = sampleTooltips
            summaries[sample] = summaryParts.isEmpty
                ? "No manual haplotype assignments"
                : "Manual haplotypes: " + summaryParts.joined(separator: "; ")
        }
        self.valuesBySample = valuesBySample
        self.tooltipsBySample = tooltipsBySample
        self.accessibilitySummaryBySample = summaries
    }

    func changedSamples(comparedTo previous: Self) -> Set<String> {
        let samples = Set(valuesBySample.keys).union(previous.valuesBySample.keys)
        return Set(samples.filter {
            valuesBySample[$0] != previous.valuesBySample[$0]
        })
    }

    func tooltip(
        sample: String,
        locus: GenotypeManualHaplotypeLocus
    ) -> String? {
        guard let locusIndex = Self.loci.firstIndex(of: locus) else {
            return nil
        }
        return tooltipsBySample[sample]?[locusIndex]
    }
}
