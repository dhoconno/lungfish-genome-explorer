import AppKit
import SwiftUI
import LungfishCore
import LungfishIO

/// Panel B for the Review lens.
///
/// Shows the evidence behind a single call: the diagnostic alleles that
/// matched, the locus's read coverage, and run-neighbor context. Renders
/// as a hosted SwiftUI view so the controller can install it into
/// `detailContainer` alongside the existing Outline / Cohort Summary
/// content.
struct GenotypeCallEvidenceView: View {
    struct Evidence: Equatable {
        let sample: String
        let locus: String
        let slot: HaplotypeSlot
        let callName: String
        let status: GenotypeHaplotypeCallStatus
        let observedGenotypeCount: Int
        let observedGenotypes: [String]
        let diagnosticAlleles: [DiagnosticAllele]
        let locusReadTotal: Int
        let neighborsBefore: [Neighbor]
        let neighborsAfter: [Neighbor]

        static let placeholder = Evidence(
            sample: "",
            locus: "",
            slot: .h1,
            callName: "",
            status: .called,
            observedGenotypeCount: 0,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 0,
            neighborsBefore: [],
            neighborsAfter: []
        )
    }

    struct DiagnosticAllele: Identifiable, Equatable {
        let allele: String
        let reads: Int
        let percentOfLocus: Double
        let isLowSupport: Bool
        var id: String { allele }
    }

    struct Neighbor: Identifiable, Equatable {
        let animalId: String
        let summary: String
        var id: String { animalId }
    }

    let evidence: Evidence?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let evidence {
                    header(evidence)
                    Divider()
                    diagnosticAlleles(evidence)
                    Divider()
                    coverageBar(evidence)
                    Divider()
                    neighbors(evidence)
                    if !evidence.observedGenotypes.isEmpty {
                        Divider()
                        observedGenotypes(evidence)
                    }
                } else {
                    emptyState
                }
            }
            .padding(14)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Call evidence")
                .font(.subheadline.weight(.semibold))
            Text("Select a sample call to see diagnostic alleles, locus coverage, and run neighbors.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(evidence.sample)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(evidence.locus)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(evidence.slot.displayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                statusChip(evidence.status)
            }
            HStack(spacing: 6) {
                Text("Call:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(evidence.callName)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func diagnosticAlleles(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostic alleles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if evidence.diagnosticAlleles.isEmpty {
                Text("No diagnostic alleles surfaced for this call.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    Text("Allele")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Reads")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text("% locus")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                ForEach(evidence.diagnosticAlleles) { allele in
                    HStack(spacing: 6) {
                        Text(allele.allele)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(allele.reads)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1f%%", allele.percentOfLocus * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(allele.isLowSupport ? Color(nsColor: .lungfishDanger) : .primary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func coverageBar(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coverage at \(evidence.locus)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if evidence.locusReadTotal == 0 {
                Text("No reads at this locus.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(evidence.diagnosticAlleles) { allele in
                            Rectangle()
                                .fill(coverageColor(for: allele))
                                .frame(width: max(2, geo.size.width * CGFloat(allele.percentOfLocus)))
                        }
                        Rectangle()
                            .fill(Color(nsColor: .secondaryLabelColor).opacity(0.2))
                    }
                }
                .frame(height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack {
                    Text("\(evidence.diagnosticAlleles.map(\.reads).reduce(0, +)) supporting · \(evidence.locusReadTotal) total at locus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func neighbors(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Neighbors in run")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                neighborColumn(label: "Previous", neighbors: evidence.neighborsBefore.suffix(1).map { $0 })
                Spacer(minLength: 8)
                neighborColumn(label: "Selected", neighbors: [Neighbor(animalId: evidence.sample, summary: evidence.callName)], highlighted: true)
                Spacer(minLength: 8)
                neighborColumn(label: "Next", neighbors: evidence.neighborsAfter.prefix(1).map { $0 })
            }
        }
    }

    private func observedGenotypes(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Observed genotypes (\(evidence.observedGenotypeCount))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(evidence.observedGenotypes.prefix(8), id: \.self) { gt in
                Text(gt)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if evidence.observedGenotypes.count > 8 {
                Text("+ \(evidence.observedGenotypes.count - 8) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func neighborColumn(label: String, neighbors: [Neighbor], highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if neighbors.isEmpty {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(neighbors) { neighbor in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(neighbor.animalId)
                            .font(.caption.monospaced())
                            .foregroundStyle(highlighted ? Color.accentColor : .primary)
                        Text(neighbor.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(highlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private func statusChip(_ status: GenotypeHaplotypeCallStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .called:            return ("Called", .secondary)
            case .specialCase:       return ("Special case", Color(nsColor: .systemOrange))
            case .noHaplotype:       return ("No haplotype", Color(nsColor: .lungfishDanger))
            case .tooManyHaplotypes: return ("Too many haplotypes", Color(nsColor: .lungfishDanger))
            case .tooManyGenotypes:  return ("Too many genotypes", Color(nsColor: .lungfishDanger))
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
            .foregroundStyle(color)
    }

    private func coverageColor(for allele: GenotypeCallEvidenceView.DiagnosticAllele) -> Color {
        if allele.isLowSupport {
            return Color(nsColor: .lungfishDanger).opacity(0.6)
        }
        return Color.accentColor
    }
}
