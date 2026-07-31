import LungfishCore
import LungfishIO
import SwiftUI

/// Artifact-lens summary for assignments edited in the selected sample's
/// Detail Inspector. Assignment creation belongs to the sample-scoped editor;
/// this section deliberately exposes only canonical saved state.
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

/// Compatibility presentation for analyses that already contain a
/// haplotyping result. Those bundles retain the pre-existing carrier-wide
/// creator instead of adopting the genotype-only sample editor.
struct GenotypeLegacyManualHaplotypingSection: View {
    let rows: [GenotypeManualHaplotypingSection.GenotypeRow]
    let manualAssignments: [ManualHaplotypeAssignment]
    @Binding var selectedGenotypeIds: Set<String>
    @Binding var draftLabel: String
    @Binding var draftColorTokenIndex: Int
    var onCreateHaplotype: () -> Void
    var onDeleteAssignment: (ManualHaplotypeAssignment) -> Void
    var onExportDefinitions: () -> Void

    var exportIsDisabled: Bool {
        manualAssignments.isEmpty
    }

    private var loci: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows where seen.insert(row.locus).inserted {
            ordered.append(row.locus)
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            existingAssignments
            Divider()
            ForEach(loci, id: \.self) { locus in
                locusGroup(locus)
                Divider()
            }
            draftEditor
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manual haplotyping")
                .font(.subheadline.weight(.semibold))
            Text(
                "No reference haplotype set is available. Group observed genotypes into haplotypes; this bundle's annotations sidecar stores the assignments."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var existingAssignments: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved haplotypes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if manualAssignments.isEmpty {
                Text("None yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(
                    Array(uniqueLabels.enumerated()),
                    id: \.offset
                ) { _, label in
                    let group = manualAssignments.filter {
                        $0.label == label
                    }
                    let alleles = group
                        .flatMap(\.diagnosticAlleles)
                        .uniqued()
                    let tokenIndex = group.first?.colorTokenIndex ?? 0
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 8
                    ) {
                        Circle()
                            .fill(
                                swiftUIColor(
                                    forTokenIndex: tokenIndex
                                )
                            )
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .font(.caption.weight(.semibold))
                            Text(alleles.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        Button {
                            for assignment in group {
                                onDeleteAssignment(assignment)
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button(
                "Export Manual Definitions\u{2026}",
                action: onExportDefinitions
            )
            .controlSize(.small)
            .disabled(exportIsDisabled)
        }
    }

    private func locusGroup(_ locus: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(locus)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let locusRows = rows.filter { $0.locus == locus }
                .sorted { $0.totalReads > $1.totalReads }
            ForEach(locusRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle(
                        isOn: Binding(
                            get: {
                                selectedGenotypeIds.contains(row.id)
                            },
                            set: { newValue in
                                if newValue {
                                    selectedGenotypeIds.insert(row.id)
                                } else {
                                    selectedGenotypeIds.remove(row.id)
                                }
                            }
                        )
                    ) {
                        Text(row.genotype)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text(
                        "\(row.sampleCount) samp\u{00B7}\(row.totalReads) rd"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Create haplotype from \(selectedGenotypeIds.count) selected"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            TextField(
                "Label (e.g. Custom-A1)",
                text: $draftLabel
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            HStack(spacing: 4) {
                ForEach(
                    0..<HaplotypeColorToken.canonicalPalette.count,
                    id: \.self
                ) { index in
                    Button {
                        draftColorTokenIndex = index
                    } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    swiftUIColor(
                                        forTokenIndex: index
                                    )
                                )
                                .frame(width: 18, height: 18)
                            if draftColorTokenIndex == index {
                                Circle()
                                    .stroke(
                                        Color.accentColor,
                                        lineWidth: 2
                                    )
                                    .frame(width: 22, height: 22)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(
                        HaplotypeColorToken
                            .canonicalPalette[index]
                            .displayName
                    )
                }
            }
            Button(
                "Create haplotype",
                action: onCreateHaplotype
            )
            .controlSize(.small)
            .disabled(
                selectedGenotypeIds.isEmpty
                    || draftLabel.isEmpty
            )
        }
    }

    private var uniqueLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for assignment in manualAssignments
        where seen.insert(assignment.label).inserted {
            ordered.append(assignment.label)
        }
        return ordered
    }

    private func swiftUIColor(forTokenIndex index: Int) -> Color {
        let palette = HaplotypeColorToken.canonicalPalette
        let safeIndex = max(0, min(palette.count - 1, index))
        let token = palette[safeIndex]
        return Color(
            red: token.fillColor.red,
            green: token.fillColor.green,
            blue: token.fillColor.blue
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
