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
        var omittedHaplotypeGenotypes: [OmittedHaplotypeGenotype] = []
        let locusReadTotal: Int
        let neighborsBefore: [Neighbor]
        let neighborsAfter: [Neighbor]
        /// Plain-English explanation of *why* the call is in error, or
        /// empty when the call is healthy. The Review-lens inspector
        /// shows it directly.
        var errorExplanation: String = ""
        /// For NO HAP errors: per-candidate-haplotype breakdown of which
        /// diagnostic alleles were observed vs missing. Empty for OK / TMH /
        /// TMG cases.
        var candidateHaplotypes: [CandidateHaplotype] = []
        /// H1 name and H2 name as the analyzer called them (may be the
        /// same for homozygous samples, or "ERR: ..." for error calls).
        /// Both shown in the inspector header so the analyst sees the full
        /// diploid call, not just one allele.
        var h1Name: String = ""
        var h2Name: String = ""
        /// Per-haplotype supporting-allele breakdown. Each entry shows
        /// which diagnostic alleles were observed for a single matched
        /// haplotype, with read counts. Surfaces for healthy calls so the
        /// analyst can see exactly which reads supported H1 vs H2.
        var perHaplotypeSupport: [PerHaplotypeSupport] = []

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

        /// True when the sample's call at this locus is homozygous
        /// (h1 == h2 with both being a real haplotype) OR effectively
        /// homozygous (h2 is "-", meaning only one haplotype was
        /// supported). Used to label the inspector header.
        var isHomozygous: Bool {
            guard status == .called || status == .specialCase else { return false }
            if h2Name.isEmpty || h2Name == "-" { return true }
            return h1Name == h2Name
        }
    }

    struct PerHaplotypeSupport: Identifiable, Equatable {
        let haplotypeName: String
        let supportingAlleles: [DiagnosticAllele]
        var id: String { haplotypeName }
    }

    struct CandidateHaplotype: Identifiable, Equatable {
        let name: String
        let observed: [String]
        let missing: [String]
        var id: String { name }
    }

    struct HaplotypeOverrideAction: Identifiable, Equatable {
        let slot: HaplotypeSlot
        let haplotypeName: String
        let label: String
        let help: String

        var id: String { "\(slot.rawValue)-\(haplotypeName)" }
    }

    struct HaplotypeOverrideRequest: Identifiable, Equatable {
        let slot: HaplotypeSlot
        let haplotypeName: String

        var id: String { "\(slot.rawValue)-\(haplotypeName)" }
    }

    struct PendingOverrides: Equatable {
        private var targets: [HaplotypeSlot: String] = [:]

        var isEmpty: Bool {
            targets.isEmpty
        }

        var requests: [HaplotypeOverrideRequest] {
            HaplotypeSlot.allCases.compactMap { slot in
                guard let haplotypeName = targets[slot] else { return nil }
                return HaplotypeOverrideRequest(slot: slot, haplotypeName: haplotypeName)
            }
        }

        mutating func stage(_ request: HaplotypeOverrideRequest) {
            targets[request.slot] = request.haplotypeName
        }

        mutating func clear() {
            targets.removeAll()
        }

        func target(for slot: HaplotypeSlot) -> String? {
            targets[slot]
        }
    }

    struct DiagnosticAllele: Identifiable, Equatable {
        let allele: String
        let reads: Int
        let percentOfLocus: Double
        let isLowSupport: Bool
        var id: String { allele }
    }

    struct OmittedHaplotypeGenotype: Identifiable, Equatable {
        let genotype: String
        let reads: Int
        let percentOfLocus: Double
        let reason: String
        var id: String { genotype }
    }

    struct Neighbor: Identifiable, Equatable {
        let animalId: String
        let summary: String
        var id: String { animalId }
    }

    let evidence: Evidence?
    /// Optional callback that fires when the analyst promotes a candidate
    /// haplotype from the review matrix.
    var onOverrideRequested: ((String, HaplotypeSlot) -> Void)?
    var onOverridesRequested: (([HaplotypeOverrideRequest]) -> Void)?
    var onConfirmRequested: (() -> Void)?
    var onSkipRequested: (() -> Void)?

    @State private var pendingOverrides = PendingOverrides()

    static func overrideActions(
        for candidate: CandidateHaplotype,
        evidence: Evidence
    ) -> [HaplotypeOverrideAction] {
        GenotypeHaplotypeOverrideTargets.expandedTargets(from: candidate.name).flatMap { target in
            [HaplotypeSlot.h1, .h2].compactMap { slot in
                overrideAction(targetName: target, evidence: evidence, slot: slot)
            }
        }
    }

    static func unresolvedOverrideActions(for evidence: Evidence) -> [HaplotypeOverrideAction] {
        [HaplotypeSlot.h1, .h2].compactMap { slot in
            overrideAction(
                targetName: GenotypeHaplotypeOverrideTargets.unresolved,
                evidence: evidence,
                slot: slot,
                isUnresolved: true
            )
        }
    }

    private static func overrideAction(
        targetName: String,
        evidence: Evidence,
        slot: HaplotypeSlot,
        isUnresolved: Bool = false
    ) -> HaplotypeOverrideAction? {
        let current = currentHaplotypeName(in: evidence, slot: slot)
        guard current != targetName else { return nil }
        let otherSlot: HaplotypeSlot = slot == .h1 ? .h2 : .h1
        let otherCurrent = currentHaplotypeName(in: evidence, slot: otherSlot)
        let displayCurrent = displayOverrideValue(current)
        let displayOther = displayOverrideValue(otherCurrent)
        let label = "\(slot.displayName): \(displayCurrent) -> \(targetName)"
        let help: String
        if isUnresolved {
            help = "Leave \(slot.displayName) unresolved at \(evidence.locus) for \(evidence.sample): \(displayCurrent) -> ?. \(otherSlot.displayName) remains \(displayOther)."
        } else {
            help = "Replace \(slot.displayName) at \(evidence.locus) for \(evidence.sample): \(displayCurrent) -> \(targetName). \(otherSlot.displayName) remains \(displayOther)."
        }
        return HaplotypeOverrideAction(
            slot: slot,
            haplotypeName: targetName,
            label: label,
            help: help
        )
    }

    private static func currentHaplotypeName(
        in evidence: Evidence,
        slot: HaplotypeSlot
    ) -> String {
        switch slot {
        case .h1: return evidence.h1Name
        case .h2: return evidence.h2Name
        }
    }

    private static func displayOverrideValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        if trimmed.hasPrefix("ERR") { return "ERR" }
        return trimmed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let evidence {
                    header(evidence)
                    if !pendingOverrides.isEmpty {
                        Divider()
                        pendingOverridesBlock(evidence)
                    }
                    if !evidence.errorExplanation.isEmpty {
                        Divider()
                        errorExplanationBlock(evidence)
                    }
                    if !evidence.perHaplotypeSupport.isEmpty {
                        Divider()
                        perHaplotypeSupportBlock(evidence)
                    }
                    if !evidence.candidateHaplotypes.isEmpty {
                        Divider()
                        candidatesBlock(evidence)
                    }
                    if !evidence.omittedHaplotypeGenotypes.isEmpty {
                        Divider()
                        omittedHaplotypeGenotypes(evidence)
                    }
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

    /// Per-haplotype supporting-allele table for healthy calls. Lists each
    /// matched haplotype (H1, H2, or just one for homozygous samples) with
    /// the diagnostic alleles that supported it and their read counts.
    private func perHaplotypeSupportBlock(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Supporting reads per haplotype")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(evidence.perHaplotypeSupport) { support in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(support.haplotypeName)
                            .font(.callout.monospaced().weight(.semibold))
                        Text("\(support.supportingAlleles.count) supporting allele\(support.supportingAlleles.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(support.supportingAlleles) { allele in
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
                    }
                }
            }
        }
    }

    /// Plain-English explanation block. Shown only for error calls so
    /// healthy `.called` rows stay quiet.
    private func errorExplanationBlock(_ evidence: Evidence) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .lungfishDanger))
            Text(evidence.errorExplanation)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-candidate-haplotype breakdown of which diagnostic alleles were
    /// observed and which were missing, with an Override action on each
    /// row so the analyst can promote a strong-but-not-called candidate
    /// to a slot directly from the inspector.
    private func candidatesBlock(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("All candidate haplotypes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("sorted by observed-allele count")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(evidence.candidateHaplotypes) { candidate in
                candidateRow(candidate, evidence: evidence)
            }
            let unresolvedActions = Self.unresolvedOverrideActions(for: evidence)
            if !unresolvedActions.isEmpty {
                unresolvedActionsRow(unresolvedActions)
            }
        }
    }

    private func unresolvedActionsRow(_ actions: [HaplotypeOverrideAction]) -> some View {
        HStack(spacing: 6) {
            Text("Leave unresolved")
                .font(.caption.monospaced().weight(.semibold))
            Text("manual unknown")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            ForEach(actions) { action in
                let isPending = pendingOverrides.target(for: action.slot) == action.haplotypeName
                Button(action.label) {
                    stageOverride(action)
                }
                .controlSize(.small)
                .lineLimit(1)
                .help(action.help)
                .accessibilityLabel(action.help)
                .foregroundStyle(isPending ? Color.accentColor : Color.primary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.04))
        )
    }

    private func candidateRow(_ candidate: CandidateHaplotype, evidence: Evidence) -> some View {
        let isCurrentCall = candidate.name == evidence.h1Name || candidate.name == evidence.h2Name
        let totalAlleles = candidate.observed.count + candidate.missing.count
        let actions = Self.overrideActions(for: candidate, evidence: evidence)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(candidate.name)
                    .font(.caption.monospaced().weight(.semibold))
                if isCurrentCall {
                    Text("CALLED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor)
                        )
                }
                Text("\(candidate.observed.count) / \(totalAlleles) alleles observed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !actions.isEmpty {
                    ForEach(actions) { action in
                        let isPending = pendingOverrides.target(for: action.slot) == action.haplotypeName
                        Button(action.label) {
                            stageOverride(action)
                        }
                        .controlSize(.small)
                        .lineLimit(1)
                        .help(action.help)
                        .accessibilityLabel(action.help)
                        .foregroundStyle(isPending ? Color.accentColor : Color.primary)
                    }
                }
            }
            if !candidate.observed.isEmpty {
                ForEach(candidate.observed, id: \.self) { allele in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("✓")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.green)
                        Text(allele)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !candidate.missing.isEmpty {
                ForEach(candidate.missing, id: \.self) { allele in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("·")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(allele)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("[not observed]")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isCurrentCall ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
        )
    }

    private func stageOverride(_ action: HaplotypeOverrideAction) {
        pendingOverrides.stage(.init(slot: action.slot, haplotypeName: action.haplotypeName))
    }

    private func pendingOverridesBlock(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pending haplotype overrides")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(pendingOverrides.requests) { request in
                HStack(spacing: 6) {
                    Text(request.slot.displayName)
                        .font(.caption.monospaced().weight(.semibold))
                        .frame(width: 24, alignment: .leading)
                    Text("\(Self.displayOverrideValue(Self.currentHaplotypeName(in: evidence, slot: request.slot))) -> \(request.haplotypeName)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("Clear") {
                    pendingOverrides.clear()
                }
                .controlSize(.small)
                Button("Apply pending") {
                    let requests = pendingOverrides.requests
                    pendingOverrides.clear()
                    if onOverridesRequested != nil {
                        onOverridesRequested?(requests)
                    } else {
                        for request in requests {
                            onOverrideRequested?(request.haplotypeName, request.slot)
                        }
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(pendingOverrides.isEmpty)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private func header(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(evidence.sample)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(evidence.locus)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                statusChip(evidence.status)
                Button("Confirm") {
                    onConfirmRequested?()
                }
                .controlSize(.small)
                .help("Confirm analyzer call")
                .accessibilityLabel("Confirm analyzer call")
                Button("Skip") {
                    onSkipRequested?()
                }
                .controlSize(.small)
                .help("Skip to next review sample")
                .accessibilityLabel("Skip to next review sample")
            }
            HStack(spacing: 6) {
                Text("Call:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(diploidCallText(evidence))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if evidence.isHomozygous {
                    Text("(homozygous)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                }
            }
        }
    }

    private func diploidCallText(_ evidence: Evidence) -> String {
        // For called samples: show "H1 / H2" or "H1 (homozygous)" when
        // both haplotypes are the same. For errors: show the error label.
        let h1 = evidence.h1Name.isEmpty ? evidence.callName : evidence.h1Name
        let h2 = evidence.h2Name
        if h2.isEmpty || h2 == "-" || h2 == h1 {
            return h1
        }
        return "\(h1) / \(h2)"
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

    private func omittedHaplotypeGenotypes(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Omitted from haplotyping")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("These retained genotype calls stayed in the run evidence but were below the haplotype thresholds recorded for this analysis.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Genotype")
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
            ForEach(evidence.omittedHaplotypeGenotypes) { genotype in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(genotype.genotype)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(genotype.reads)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1f%%", genotype.percentOfLocus * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color(nsColor: .lungfishDanger))
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text(genotype.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
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
            case .notAssayed:        return ("Not assayed", Color(nsColor: .systemOrange))
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
