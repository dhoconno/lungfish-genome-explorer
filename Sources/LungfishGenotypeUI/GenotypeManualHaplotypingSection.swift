import LungfishIO
import SwiftUI

/// Artifact-lens summary for assignments edited in the selected sample's
/// Detail Inspector. Assignment creation belongs to the sample-scoped editor;
/// this section deliberately exposes only canonical saved state and export.
struct GenotypeManualHaplotypingSection: View {
    /// Retained as a compatibility value for callers that still build a
    /// genotype digest. The artifact-lens UI no longer offers bulk creation
    /// from these rows.
    struct GenotypeRow: Identifiable, Equatable {
        let locus: String
        let genotype: String
        let sampleCount: Int
        let totalReads: Int
        var id: String { "\(locus)::\(genotype)" }
    }

    let manualAssignments: [ManualHaplotypeAssignment]
    var onExportDefinitions: () -> Void

    var exportIsDisabled: Bool {
        manualAssignments.isEmpty
    }

    var assignmentSummary: String {
        let count = manualAssignments.count
        return "\(count) canonical assignment\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual haplotype assignments")
                .font(.subheadline.weight(.semibold))
            Text(
                "Select one sample column to add or edit its ordered H1 and H2 assignments in the Detail Inspector."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            if manualAssignments.isEmpty {
                Text("No saved assignments.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(assignmentSummary)
                    .font(.caption.weight(.semibold))
                ForEach(sampleSummaries, id: \.sample) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.sample)
                            .font(.caption.weight(.semibold))
                        Text(summary.labels)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            Button(
                "Export Manual Definitions\u{2026}",
                action: onExportDefinitions
            )
            .controlSize(.small)
            .disabled(exportIsDisabled)
            .accessibilityIdentifier("manual-haplotype-export-definitions")
        }
    }

    private var sampleSummaries: [(sample: String, labels: String)] {
        Dictionary(grouping: manualAssignments, by: \.sample)
            .map { sample, assignments in
                let ordered = assignments.sorted {
                    let leftLocus =
                        GenotypeManualHaplotypeLocus(normalizing: $0.locus)
                    let rightLocus =
                        GenotypeManualHaplotypeLocus(normalizing: $1.locus)
                    let leftIndex = leftLocus.flatMap {
                        GenotypeManualHaplotypeLocus.allCases.firstIndex(of: $0)
                    } ?? .max
                    let rightIndex = rightLocus.flatMap {
                        GenotypeManualHaplotypeLocus.allCases.firstIndex(of: $0)
                    } ?? .max
                    if leftIndex != rightIndex {
                        return leftIndex < rightIndex
                    }
                    return $0.slot.rawValue < $1.slot.rawValue
                }
                let labels = ordered.map { assignment in
                    let locus =
                        GenotypeManualHaplotypeLocus(
                            normalizing: assignment.locus
                        )?.workbookLabel ?? assignment.locus
                    return "\(locus) \(assignment.slot.displayName): \(assignment.label)"
                }
                return (sample, labels.joined(separator: " \u{2022} "))
            }
            .sorted { $0.sample.localizedStandardCompare($1.sample) == .orderedAscending }
    }
}
