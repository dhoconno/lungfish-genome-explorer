import SwiftUI
import LungfishCore
import LungfishIO

/// Inspector section for assigning haplotypes to samples when the active
/// reference set has no built-in `GenotypeHaplotypeDefinitionSet`. The
/// analyst sees one row per (locus, genotype) observed in the cohort and can
/// group selected genotypes into a named haplotype with a chosen color token.
struct GenotypeManualHaplotypingSection: View {
    struct GenotypeRow: Identifiable, Equatable {
        let locus: String
        let genotype: String
        let sampleCount: Int
        let totalReads: Int
        var id: String { "\(locus)::\(genotype)" }
    }

    let rows: [GenotypeRow]
    let manualAssignments: [ManualHaplotypeAssignment]
    @Binding var selectedGenotypeIds: Set<String>
    @Binding var draftLabel: String
    @Binding var draftColorTokenIndex: Int
    var allowsCreation = true
    var onCreateHaplotype: () -> Void
    var onDeleteAssignment: (ManualHaplotypeAssignment) -> Void
    var onExportDefinitions: () -> Void

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
            if allowsCreation {
                Divider()
                ForEach(loci, id: \.self) { locus in
                    locusGroup(locus)
                    Divider()
                }
                draftEditor
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manual haplotyping")
                .font(.subheadline.weight(.semibold))
            Text(
                allowsCreation
                    ? "No reference haplotype set is available. Group observed genotypes into haplotypes; this bundle's annotations sidecar stores the assignments."
                    : "Saved manual haplotype assignments from this bundle's annotations sidecar."
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
                ForEach(Array(uniqueLabels.enumerated()), id: \.offset) { _, label in
                    let group = manualAssignments.filter { $0.label == label }
                    let alleles = group.flatMap(\.diagnosticAlleles).uniqued()
                    let tokenIndex = group.first?.colorTokenIndex ?? 0
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(swiftUIColor(forTokenIndex: tokenIndex))
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
            Button("Export Manual Definitions\u{2026}", action: onExportDefinitions)
                .controlSize(.small)
                .disabled(manualAssignments.isEmpty)
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
                    Toggle(isOn: Binding(
                        get: { selectedGenotypeIds.contains(row.id) },
                        set: { newValue in
                            if newValue { selectedGenotypeIds.insert(row.id) }
                            else { selectedGenotypeIds.remove(row.id) }
                        }
                    )) {
                        Text(row.genotype)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text("\(row.sampleCount) samp\u{00B7}\(row.totalReads) rd")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create haplotype from \(selectedGenotypeIds.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Label (e.g. Custom-A1)", text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            HStack(spacing: 4) {
                ForEach(0..<HaplotypeColorToken.canonicalPalette.count, id: \.self) { index in
                    Button {
                        draftColorTokenIndex = index
                    } label: {
                        ZStack {
                            Circle()
                                .fill(swiftUIColor(forTokenIndex: index))
                                .frame(width: 18, height: 18)
                            if draftColorTokenIndex == index {
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(HaplotypeColorToken.canonicalPalette[index].displayName)
                }
            }
            Button("Create haplotype", action: onCreateHaplotype)
                .controlSize(.small)
                .disabled(selectedGenotypeIds.isEmpty || draftLabel.isEmpty)
        }
    }

    private var uniqueLabels: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for assignment in manualAssignments where seen.insert(assignment.label).inserted {
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
