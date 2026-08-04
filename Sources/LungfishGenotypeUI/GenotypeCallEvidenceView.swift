import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

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
        var sampleTotalReads: Int? = nil
        var sampleFullLengthReads: Int? = nil
        var sampleAssignedGenotypeReads: Int? = nil
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
        /// All retained genotype observations for the selected animal.
        /// Rows are marked when they contributed diagnostic support to
        /// deterministic haplotyping.
        var animalGenotypes: [AnimalGenotype] = []
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
        /// All defined haplotypes for this locus in the active definition
        /// set. The override pulldown uses this to expose cautious manual
        /// assignment choices even when no genotype reads support them.
        var availableHaplotypeNames: [String] = []

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

    struct AnimalGenotype: Identifiable, Equatable {
        let genotype: String
        let locus: String
        let reads: Int
        let isDiagnosticForCall: Bool
        let associatedHaplotypes: [String]

        var id: String { "\(locus)\u{1F}\(genotype)" }
    }

    enum GenotypeAgreement: Equatable {
        case agreesWithCalledHaplotype
        case outsideCalledHaplotypes
    }

    struct GenotypeEvidenceSection: Identifiable, Comparable, Hashable {
        let title: String
        let sortIndex: Int

        var id: String { title }

        init(_ row: AnimalGenotype) {
            let title = Self.sectionTitle(for: row)
            self.title = title
            self.sortIndex = Self.orderedTitles.firstIndex(of: title) ?? Self.orderedTitles.count
        }

        static func < (lhs: GenotypeEvidenceSection, rhs: GenotypeEvidenceSection) -> Bool {
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        static let orderedTitles = [
            "Mafa-F",
            "Mafa-G",
            "Mafa-AG",
            "Mafa-A",
            "Mafa-70",
            "Mafa-E",
            "Mafa-B",
            "Mafa-DRB",
            "Mafa-DQA/DQB",
            "Mafa-DPA/DPB",
        ]

        private static func sectionTitle(for row: AnimalGenotype) -> String {
            let metadata = AlleleLabel.metadata(from: row.genotype)
            let source = [
                metadata["source_loci"],
                metadata["source_locus"],
                metadata["haplotype_groups"],
                metadata["locus"],
                row.locus,
                AlleleLabel.identifier(from: row.genotype),
                row.genotype,
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .uppercased()

            if source.contains("DQA") || source.contains("DQB") || source.contains("MHC-DQ") || source.contains("MAFA-DQ") {
                return "Mafa-DQA/DQB"
            }
            if source.contains("DPA") || source.contains("DPB") || source.contains("MHC-DP") || source.contains("MAFA-DP") {
                return "Mafa-DPA/DPB"
            }
            if source.contains("DRB") || source.contains("MHC-DR") || source.contains("MAFA-DR") {
                return "Mafa-DRB"
            }
            if source.contains("MHC-B") || source.contains("MAFA-B") || source.contains("_B_") {
                return "Mafa-B"
            }
            if source.contains("MHC-F") || source.contains("MAFA-F") || source.contains("_F_") {
                return "Mafa-F"
            }
            if source.contains("MHC-G") || source.contains("MAFA-G") || source.contains("_G_") {
                return "Mafa-G"
            }
            if source.contains("MHC-AG") || source.contains("MAFA-AG") || source.contains("_AG_") {
                return "Mafa-AG"
            }
            if source.contains("MHC-70") || source.contains("MAFA-70") || source.contains("_70_") {
                return "Mafa-70"
            }
            if source.contains("MHC-E") || source.contains("MAFA-E") || source.contains("_E_") {
                return "Mafa-E"
            }
            if source.contains("MHC-A") || source.contains("MAFA-A") || source.contains("_A") {
                return "Mafa-A"
            }
            return row.locus.isEmpty ? "Other" : row.locus
        }

        static func subsectionRank(for row: AnimalGenotype) -> Int {
            let source = subsectionSource(for: row)
            if source.contains("DQA") || source.contains("DPA") {
                return 0
            }
            if source.contains("DQB") || source.contains("DPB") {
                return 1
            }
            return 0
        }

        private static func subsectionSource(for row: AnimalGenotype) -> String {
            let metadata = AlleleLabel.metadata(from: row.genotype)
            return [
                metadata["source_loci"],
                metadata["source_locus"],
                AlleleLabel.identifier(from: row.genotype),
                row.genotype,
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .uppercased()
        }
    }

    struct HaplotypeOverrideAction: Identifiable, Equatable {
        let slot: HaplotypeSlot
        let haplotypeName: String
        let label: String
        let help: String

        var id: String { "\(slot.rawValue)-\(haplotypeName)" }
    }

    struct HaplotypeOverrideActionSections: Equatable {
        let recommended: [HaplotypeOverrideAction]
        let unsupported: [HaplotypeOverrideAction]
        let unresolved: [HaplotypeOverrideAction]

        var isEmpty: Bool {
            recommended.isEmpty && unsupported.isEmpty && unresolved.isEmpty
        }
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

    struct AlleleLabel: Equatable {
        let primary: String
        let secondary: String
        let badge: String?
        let associatedHaplotypes: [String]
        let fullHeader: String

        init(_ rawValue: String) {
            let fullHeader = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata = Self.metadata(from: fullHeader)
            let identifier = Self.identifier(from: fullHeader)
            let alleleNames = metadata["alleles"].map(Self.displayAlleles(from:))
            let conventionalName = alleleNames?.isEmpty == false ? alleleNames! : nil
            self.primary = conventionalName ?? identifier
            self.secondary = ""
            self.badge = Self.badge(from: metadata["evidence_classes"])
            self.associatedHaplotypes = Self.haplotypes(from: metadata["haplotypes"])
            self.fullHeader = fullHeader
        }

        static func identifier(from value: String) -> String {
            value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? value
        }

        static func metadata(from value: String) -> [String: String] {
            var fields: [String: String] = [:]
            for part in value.split(separator: "|").dropFirst() {
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { continue }
                let key = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    fields[key] = value
                }
            }
            return fields
        }

        private static func displayAlleles(from value: String) -> String {
            value.split(separator: ",")
                .map { formatMafaAllele(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }

        private static func formatMafaAllele(_ value: String) -> String {
            guard (value.hasPrefix("Mafa-") || value.hasPrefix("Mamu-")),
                  let underscore = value.firstIndex(of: "_") else {
                return value
            }
            var formatted = value
            formatted.replaceSubrange(underscore...underscore, with: "*")
            return formatted
        }

        private static func badge(from evidenceClass: String?) -> String? {
            guard let evidenceClass, !evidenceClass.isEmpty else { return nil }
            let lowercased = evidenceClass.lowercased()
            if lowercased.contains("primary") { return "primary" }
            if lowercased.contains("secondary") { return "secondary" }
            return evidenceClass
        }

        private static func haplotypes(from value: String?) -> [String] {
            guard let value else { return [] }
            var seen = Set<String>()
            return value.split(separator: ",").compactMap { rawValue in
                let token = String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty, seen.insert(token).inserted else { return nil }
                return token
            }
        }
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
    var onOverrideRequested: ((String, HaplotypeSlot) ->
        GenotypeHaplotypeMutationOutcome)?
    var onOverridesRequested: (([HaplotypeOverrideRequest]) ->
        GenotypeHaplotypeMutationOutcome)?
    var onConfirmRequested: (() -> Void)?
    var onSkipRequested: (() -> Void)?
    var typographyModel: ContentTypographyModel = .shared

    @State private var pendingOverrides = PendingOverrides()
    @State private var hiddenGenotypeSections: Set<String> = []

    init(
        evidence: Evidence?,
        onOverrideRequested: ((String, HaplotypeSlot) ->
            GenotypeHaplotypeMutationOutcome)? = nil,
        onOverridesRequested: (([HaplotypeOverrideRequest]) ->
            GenotypeHaplotypeMutationOutcome)? = nil,
        onConfirmRequested: (() -> Void)? = nil,
        onSkipRequested: (() -> Void)? = nil,
        typographyModel: ContentTypographyModel = .shared,
        initialPendingOverrides: PendingOverrides = .init()
    ) {
        self.evidence = evidence
        self.onOverrideRequested = onOverrideRequested
        self.onOverridesRequested = onOverridesRequested
        self.onConfirmRequested = onConfirmRequested
        self.onSkipRequested = onSkipRequested
        self.typographyModel = typographyModel
        _pendingOverrides = State(initialValue: initialPendingOverrides)
    }

    private var contentEmphasizedFont: Font { typographyModel.font(for: .emphasizedBody) }
    private var contentCaptionFont: Font { typographyModel.font(for: .caption) }
    private var contentMonospacedFont: Font { typographyModel.font(for: .monospaced) }

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

    static func overrideActionSections(
        for slot: HaplotypeSlot,
        evidence: Evidence
    ) -> HaplotypeOverrideActionSections {
        let recommended = deduplicatedOverrideActions(
            evidence.candidateHaplotypes.flatMap { overrideActions(for: $0, evidence: evidence) },
            slot: slot
        )
        let recommendedNames = Set(recommended.map(\.haplotypeName))
        let unsupportedTargets = evidence.availableHaplotypeNames
            .flatMap(GenotypeHaplotypeOverrideTargets.expandedTargets)
            .filter { !recommendedNames.contains($0) }
        let unsupported = deduplicatedOverrideActions(
            unsupportedTargets.compactMap { target in
                overrideAction(
                    targetName: target,
                    evidence: evidence,
                    slot: slot,
                    isUnsupported: true
                )
            },
            slot: slot
        )
        let unresolved = deduplicatedOverrideActions(unresolvedOverrideActions(for: evidence), slot: slot)
        return HaplotypeOverrideActionSections(
            recommended: recommended,
            unsupported: unsupported,
            unresolved: unresolved
        )
    }

    static func selectionReason(for candidate: CandidateHaplotype, evidence: Evidence) -> String {
        var selectedSlots: [String] = []
        if candidate.name == evidence.h1Name {
            selectedSlots.append(HaplotypeSlot.h1.displayName)
        }
        if candidate.name == evidence.h2Name {
            selectedSlots.append(HaplotypeSlot.h2.displayName)
        }
        if !selectedSlots.isEmpty {
            return "Selected for \(selectedSlots.joined(separator: " and "))"
        }
        if candidate.observed.isEmpty {
            return "Not selected: no diagnostic alleles observed"
        }
        if candidate.missing.count == 1 {
            return "Not selected: missing 1 diagnostic allele"
        }
        if candidate.missing.count > 1 {
            return "Not selected: missing \(candidate.missing.count) diagnostic alleles"
        }
        return "Not selected: deterministic rules favored the selected diploid call"
    }

    static func genotypeAgreement(_ row: AnimalGenotype, evidence: Evidence) -> GenotypeAgreement {
        if row.isDiagnosticForCall {
            return .agreesWithCalledHaplotype
        }
        let called = Set(calledHaplotypeTokens(in: evidence))
        let associated = Set(row.associatedHaplotypes.flatMap(expandedHaplotypeTokens))
        if !called.isEmpty && !associated.isEmpty && !called.isDisjoint(with: associated) {
            return .agreesWithCalledHaplotype
        }
        return .outsideCalledHaplotypes
    }

    static func displayAlleleLabel(_ value: String) -> String {
        AlleleLabel(value).primary
    }

    private static func calledHaplotypeTokens(in evidence: Evidence) -> [String] {
        [evidence.h1Name, evidence.h2Name].flatMap(expandedHaplotypeTokens)
    }

    private static func expandedHaplotypeTokens(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", !trimmed.hasPrefix("ERR"), trimmed != "?" else { return [] }
        var tokens = [trimmed]
        if let match = trimmed.range(of: #"^M\d+"#, options: .regularExpression) {
            tokens.append(String(trimmed[match]))
        }
        return Array(Set(tokens))
    }

    private static func overrideAction(
        targetName: String,
        evidence: Evidence,
        slot: HaplotypeSlot,
        isUnresolved: Bool = false,
        isUnsupported: Bool = false
    ) -> HaplotypeOverrideAction? {
        let current = currentHaplotypeName(in: evidence, slot: slot)
        guard current != targetName else { return nil }
        let otherSlot: HaplotypeSlot = slot == .h1 ? .h2 : .h1
        let otherCurrent = currentHaplotypeName(in: evidence, slot: otherSlot)
        let displayCurrent = displayOverrideValue(current)
        let displayOther = displayOverrideValue(otherCurrent)
        let baseLabel = "\(slot.displayName): \(displayCurrent) -> \(targetName)"
        let label = isUnsupported ? "\(baseLabel) (no genotype support)" : baseLabel
        let help: String
        if isUnresolved {
            help = "Leave \(slot.displayName) unresolved at \(evidence.locus) for \(evidence.sample): \(displayCurrent) -> ?. \(otherSlot.displayName) remains \(displayOther)."
        } else if isUnsupported {
            help = "Replace \(slot.displayName) at \(evidence.locus) for \(evidence.sample): \(displayCurrent) -> \(targetName). \(otherSlot.displayName) remains \(displayOther). No retained genotype support was detected for this haplotype at this locus; use only when linked-locus evidence justifies the assignment."
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

    private static func deduplicatedOverrideActions(
        _ actions: [HaplotypeOverrideAction],
        slot: HaplotypeSlot
    ) -> [HaplotypeOverrideAction] {
        var seen = Set<String>()
        return actions.filter { action in
            guard action.slot == slot else { return false }
            return seen.insert(action.haplotypeName).inserted
        }
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
                    Divider()
                    haplotypeSlotCards(evidence)
                    if !evidence.omittedHaplotypeGenotypes.isEmpty {
                        Divider()
                        omittedHaplotypeGenotypes(evidence)
                    }
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
                .font(contentEmphasizedFont)
            Text("Select a sample call to see haplotype support and retained genotype evidence.")
                .font(contentCaptionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func haplotypeSlotCards(_ evidence: Evidence) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                slotCard(.h1, evidence: evidence)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                slotCard(.h2, evidence: evidence)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                if hasUncalledCandidateHaplotypes(evidence) {
                    candidateAlternativesCard(evidence)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                animalGenotypesColumn(evidence)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 10) {
                slotCard(.h1, evidence: evidence)
                slotCard(.h2, evidence: evidence)
                if hasUncalledCandidateHaplotypes(evidence) {
                    candidateAlternativesCard(evidence)
                }
                animalGenotypesColumn(evidence)
            }
        }
    }

    private func hasUncalledCandidateHaplotypes(_ evidence: Evidence) -> Bool {
        evidence.candidateHaplotypes.contains { candidate in
            candidate.name != evidence.h1Name && candidate.name != evidence.h2Name
        }
    }

    private func slotCard(_ slot: HaplotypeSlot, evidence: Evidence) -> some View {
        let value = Self.currentHaplotypeName(in: evidence, slot: slot)
        let displayValue = Self.displayOverrideValue(value)
        let support = supportForSlot(slot, evidence: evidence)
        let alleles = support?.supportingAlleles ?? []
        let reads = alleles.reduce(0) { $0 + $1.reads }
        let candidate = candidateForSlot(slot, evidence: evidence)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(slot.displayName)
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(displayValue)
                    .font(contentEmphasizedFont.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                slotOverrideMenu(slot, evidence: evidence)
            }
            HStack(spacing: 8) {
                Text("\(alleles.count) allele\(alleles.count == 1 ? "" : "s")")
                    .font(contentCaptionFont)
                    .foregroundStyle(.secondary)
                Text("\(reads) reads")
                    .font(contentCaptionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                if slot == .h2 && (value.isEmpty || value == "-") {
                    Text("homozygous evidence")
                        .font(contentCaptionFont)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Divider()
            if alleles.isEmpty {
                Text("No diagnostic support assigned to this slot.")
                    .font(contentCaptionFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(alleles) { allele in
                    diagnosticAlleleReadRow(allele, compact: true)
                }
            }
            if let candidate, !candidate.missing.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Missing diagnostics")
                        .font(contentCaptionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(candidate.missing, id: \.self) { allele in
                        compactAlleleLine(Self.displayAlleleLabel(allele), marker: "missing")
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }

    private func supportForSlot(
        _ slot: HaplotypeSlot,
        evidence: Evidence
    ) -> PerHaplotypeSupport? {
        let value = Self.currentHaplotypeName(in: evidence, slot: slot)
        let target = (slot == .h2 && (value.isEmpty || value == "-")) ? evidence.h1Name : value
        return evidence.perHaplotypeSupport.first { $0.haplotypeName == target }
    }

    private func candidateForSlot(
        _ slot: HaplotypeSlot,
        evidence: Evidence
    ) -> CandidateHaplotype? {
        let value = Self.currentHaplotypeName(in: evidence, slot: slot)
        let target = (slot == .h2 && (value.isEmpty || value == "-")) ? evidence.h1Name : value
        return evidence.candidateHaplotypes.first { $0.name == target }
    }

    private func slotOverrideMenu(_ slot: HaplotypeSlot, evidence: Evidence) -> some View {
        let sections = Self.overrideActionSections(for: slot, evidence: evidence)
        return Menu {
            ForEach(sections.recommended) { action in
                overrideMenuButton(action)
            }
            if !sections.unsupported.isEmpty {
                if !sections.recommended.isEmpty {
                    Divider()
                }
                ForEach(sections.unsupported) { action in
                    overrideMenuButton(action)
                }
            }
            if !sections.unresolved.isEmpty {
                if !sections.recommended.isEmpty || !sections.unsupported.isEmpty {
                    Divider()
                }
                ForEach(sections.unresolved) { action in
                    overrideMenuButton(action)
                }
            }
        } label: {
            Label("Change", systemImage: "arrow.left.arrow.right")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .disabled(sections.isEmpty)
        .help("Change \(slot.displayName) assignment")
    }

    private func overrideMenuButton(_ action: HaplotypeOverrideAction) -> some View {
        let isPending = pendingOverrides.target(for: action.slot) == action.haplotypeName
        return Button(isPending ? "\(action.label) (pending)" : action.label) {
            stageOverride(action)
        }
        .help(action.help)
    }

    private func animalGenotypesColumn(_ evidence: Evidence) -> some View {
        let visibleRows = evidence.animalGenotypes.filter { row in
            !hiddenGenotypeSections.contains(GenotypeEvidenceSection(row).title)
        }
        let groupedRows = Dictionary(grouping: visibleRows) { GenotypeEvidenceSection($0) }
        let sections = groupedRows.keys.sorted()
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Animal genotypes")
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(visibleRows.count) / \(evidence.animalGenotypes.count)")
                    .font(contentCaptionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                genotypeSectionVisibilityMenu(evidence)
            }
            if evidence.animalGenotypes.isEmpty {
                Text("No retained genotype observations were available for this animal.")
                    .font(contentCaptionFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sections.isEmpty {
                Text("All genotype sections are hidden.")
                    .font(contentCaptionFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sections) { section in
                    genotypeSection(section, rows: groupedRows[section] ?? [])
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }

    private func genotypeSectionVisibilityMenu(_ evidence: Evidence) -> some View {
        let sections = Set(evidence.animalGenotypes.map { GenotypeEvidenceSection($0) }).sorted()
        return Menu {
            ForEach(sections) { section in
                Button {
                    if hiddenGenotypeSections.contains(section.title) {
                        hiddenGenotypeSections.remove(section.title)
                    } else {
                        hiddenGenotypeSections.insert(section.title)
                    }
                } label: {
                    Label(
                        section.title,
                        systemImage: hiddenGenotypeSections.contains(section.title) ? "square" : "checkmark.square"
                    )
                }
            }
            Divider()
            Button("Show all") {
                hiddenGenotypeSections.removeAll()
            }
            .disabled(hiddenGenotypeSections.isEmpty)
        } label: {
            Label("Show or hide genotype loci", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .disabled(sections.isEmpty)
        .help("Show or hide genotype sections")
    }

    private func genotypeSection(
        _ section: GenotypeEvidenceSection,
        rows: [AnimalGenotype]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(rows.count)")
                    .font(contentCaptionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(rows.sorted { lhs, rhs in genotypeRowSort(lhs, rhs, section: section) }) { row in
                animalGenotypeRow(row)
            }
        }
        .padding(.top, 2)
    }

    private func animalGenotypeRow(_ row: AnimalGenotype) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                alleleLabelView(row.genotype, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(row.reads)")
                    .font(contentCaptionFont.monospacedDigit().weight(.semibold))
                    .frame(width: 42, alignment: .trailing)
            }
            HStack(spacing: 5) {
                Text(row.locus)
                    .font(contentCaptionFont.monospaced())
                    .foregroundStyle(.secondary)
                genotypeEvidencePill(row)
                if !row.associatedHaplotypes.isEmpty {
                    ForEach(row.associatedHaplotypes.prefix(5), id: \.self) { haplotype in
                        Text(haplotype)
                            .font(contentCaptionFont.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                    }
                    if row.associatedHaplotypes.count > 5 {
                        Text("+\(row.associatedHaplotypes.count - 5)")
                            .font(contentCaptionFont.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(genotypeRowBackground(row))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(genotypeRowBorder(row), lineWidth: row.isDiagnosticForCall ? 1 : 0.75)
        )
        .help(genotypeRowHelp(row))
    }

    private func genotypeRowSort(
        _ lhs: AnimalGenotype,
        _ rhs: AnimalGenotype,
        section: GenotypeEvidenceSection
    ) -> Bool {
        if section.title == "Mafa-DQA/DQB" || section.title == "Mafa-DPA/DPB" {
            let lhsSubsection = GenotypeEvidenceSection.subsectionRank(for: lhs)
            let rhsSubsection = GenotypeEvidenceSection.subsectionRank(for: rhs)
            if lhsSubsection != rhsSubsection {
                return lhsSubsection < rhsSubsection
            }
        }
        let lhsRank = genotypeEvidenceRank(lhs)
        let rhsRank = genotypeEvidenceRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.reads != rhs.reads {
            return lhs.reads > rhs.reads
        }
        return lhs.genotype.localizedStandardCompare(rhs.genotype) == .orderedAscending
    }

    private func genotypeEvidenceRank(_ row: AnimalGenotype) -> Int {
        if row.isDiagnosticForCall {
            return 0
        }
        if !row.associatedHaplotypes.isEmpty {
            return 1
        }
        return 2
    }

    private func genotypeAgreement(_ row: AnimalGenotype) -> GenotypeAgreement {
        guard let evidence else {
            return row.isDiagnosticForCall || !row.associatedHaplotypes.isEmpty
                ? .agreesWithCalledHaplotype
                : .outsideCalledHaplotypes
        }
        return Self.genotypeAgreement(row, evidence: evidence)
    }

    private func genotypeEvidenceLabel(_ row: AnimalGenotype) -> String {
        if row.isDiagnosticForCall {
            return "Diagnostic"
        }
        if !row.associatedHaplotypes.isEmpty {
            return "Associated"
        }
        return "Other"
    }

    private func genotypeEvidenceColor(_ row: AnimalGenotype) -> Color {
        switch genotypeAgreement(row) {
        case .agreesWithCalledHaplotype:
            return Color(nsColor: .systemGreen)
        case .outsideCalledHaplotypes:
            return Color(nsColor: .lungfishDanger)
        }
    }

    private func genotypeEvidencePill(_ row: AnimalGenotype) -> some View {
        Text(genotypeEvidenceLabel(row))
            .font(contentCaptionFont.weight(.semibold))
            .foregroundStyle(genotypeEvidenceColor(row))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(genotypeEvidenceColor(row).opacity(0.12))
            )
    }

    private func genotypeRowBackground(_ row: AnimalGenotype) -> Color {
        switch genotypeAgreement(row) {
        case .agreesWithCalledHaplotype:
            return Color(nsColor: .systemGreen).opacity(0.07)
        case .outsideCalledHaplotypes:
            return Color(nsColor: .lungfishDanger).opacity(0.07)
        }
    }

    private func genotypeRowBorder(_ row: AnimalGenotype) -> Color {
        switch genotypeAgreement(row) {
        case .agreesWithCalledHaplotype:
            return Color(nsColor: .systemGreen).opacity(0.28)
        case .outsideCalledHaplotypes:
            return Color(nsColor: .lungfishDanger).opacity(0.24)
        }
    }

    private func genotypeRowHelp(_ row: AnimalGenotype) -> String {
        var parts = [AlleleLabel(row.genotype).fullHeader]
        parts.append("\(row.reads) retained reads")
        parts.append(genotypeEvidenceLabel(row))
        if !row.associatedHaplotypes.isEmpty {
            parts.append("Associated haplotypes: \(row.associatedHaplotypes.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    /// Plain-English explanation block. Shown only for error calls so
    /// healthy `.called` rows stay quiet.
    private func errorExplanationBlock(_ evidence: Evidence) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .lungfishDanger))
            Text(evidence.errorExplanation)
                .font(contentCaptionFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-candidate-haplotype breakdown of which diagnostic alleles were
    /// observed and which were missing, with an Override action on each
    /// row so the analyst can promote a strong-but-not-called candidate
    /// to a slot directly from the inspector.
    private func candidateAlternativesCard(_ evidence: Evidence) -> some View {
        let candidates = evidence.candidateHaplotypes.filter { candidate in
            candidate.name != evidence.h1Name && candidate.name != evidence.h2Name
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Other possible haplotypes")
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(candidates.count)")
                    .font(contentCaptionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Why alternatives were not selected")
                .font(contentCaptionFont)
                .foregroundStyle(.tertiary)
            ForEach(candidates) { candidate in
                candidateRow(candidate, evidence: evidence)
            }
            let unresolvedActions = Self.unresolvedOverrideActions(for: evidence)
            if !unresolvedActions.isEmpty {
                unresolvedActionsRow(unresolvedActions)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }

    private func unresolvedActionsRow(_ actions: [HaplotypeOverrideAction]) -> some View {
        HStack(spacing: 6) {
            Text("Leave unresolved")
                .font(contentCaptionFont.monospaced().weight(.semibold))
            Text("manual unknown")
                .font(contentCaptionFont)
                .foregroundStyle(.secondary)
            Spacer()
            ForEach(actions) { action in
                let isPending = pendingOverrides.target(for: action.slot) == action.haplotypeName
                GenotypeMutationActionButton(
                    title: action.label,
                    accessibilityIdentifier:
                        "genotype-call-evidence-stage-"
                        + "\(action.slot.rawValue)-\(action.haplotypeName)",
                    help: action.help,
                    tintColor: isPending ? .controlAccentColor : nil,
                    action: { stageOverride(action) }
                )
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
                    .font(contentCaptionFont.monospaced().weight(.semibold))
                if isCurrentCall {
                    Text("CALLED")
                        .font(contentCaptionFont.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor)
                        )
                }
                Text("\(candidate.observed.count) / \(totalAlleles) alleles observed")
                    .font(contentCaptionFont)
                    .foregroundStyle(.secondary)
                Text(Self.selectionReason(for: candidate, evidence: evidence))
                    .font(contentCaptionFont)
                    .foregroundStyle(isCurrentCall ? Color.accentColor : .secondary)
                Spacer()
                if !actions.isEmpty {
                    ForEach(actions) { action in
                        let isPending = pendingOverrides.target(for: action.slot) == action.haplotypeName
                        GenotypeMutationActionButton(
                            title: action.label,
                            accessibilityIdentifier:
                                "genotype-call-evidence-stage-"
                                + "\(action.slot.rawValue)-"
                                + action.haplotypeName,
                            help: action.help,
                            tintColor:
                                isPending ? .controlAccentColor : nil,
                            action: { stageOverride(action) }
                        )
                    }
                }
            }
            if !candidate.observed.isEmpty {
                ForEach(candidate.observed, id: \.self) { allele in
                    compactAlleleLine(allele, marker: "observed")
                }
            }
            if !candidate.missing.isEmpty {
                ForEach(candidate.missing, id: \.self) { allele in
                    compactAlleleLine(Self.displayAlleleLabel(allele), marker: "missing")
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
                .font(contentCaptionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(pendingOverrides.requests) { request in
                HStack(spacing: 6) {
                    Text(request.slot.displayName)
                        .font(contentCaptionFont.monospaced().weight(.semibold))
                        .frame(width: 24, alignment: .leading)
                    Text("\(Self.displayOverrideValue(Self.currentHaplotypeName(in: evidence, slot: request.slot))) -> \(request.haplotypeName)")
                        .font(contentCaptionFont.monospaced())
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
                GenotypeMutationActionButton(
                    title: "Apply pending",
                    accessibilityIdentifier:
                        "genotype-call-evidence-apply-pending",
                    isEnabled: !pendingOverrides.isEmpty,
                    keyEquivalent: "\r"
                ) {
                    let requests = pendingOverrides.requests
                    let outcome: GenotypeHaplotypeMutationOutcome
                    if let onOverridesRequested {
                        outcome = onOverridesRequested(requests)
                    } else if let onOverrideRequested {
                        let outcomes = requests.map {
                            onOverrideRequested(
                                $0.haplotypeName,
                                $0.slot
                            )
                        }
                        if outcomes.contains(.failure) {
                            outcome = .failure
                        } else if outcomes.contains(.changed) {
                            outcome = .changed
                        } else {
                            outcome = .unchanged
                        }
                    } else {
                        outcome = .failure
                    }
                    if outcome == .changed {
                        pendingOverrides.clear()
                    }
                }
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
                    .font(contentEmphasizedFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(evidence.locus)
                    .font(contentMonospacedFont)
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
                    .font(contentCaptionFont)
                    .foregroundStyle(.secondary)
                Text(diploidCallText(evidence))
                    .font(contentMonospacedFont)
                    .textSelection(.enabled)
                if evidence.isHomozygous {
                    Text("(homozygous)")
                        .font(contentCaptionFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                }
            }
            HStack(spacing: 10) {
                readMetricLabel("Reads", evidence.sampleTotalReads)
                readMetricLabel("Full-length", evidence.sampleFullLengthReads)
                readMetricLabel("Assigned", evidence.sampleAssignedGenotypeReads)
            }
        }
    }

    private func readMetricLabel(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(contentCaptionFont)
                .foregroundStyle(.secondary)
            Text(value.map { $0.formatted(.number) } ?? "Unavailable")
                .font(contentCaptionFont.monospacedDigit())
                .foregroundStyle(.primary)
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

    private func diagnosticAlleleReadRow(
        _ allele: DiagnosticAllele,
        compact: Bool
    ) -> some View {
        HStack(spacing: 6) {
            alleleLabelView(allele.allele, compact: compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(allele.reads)")
                .font(contentCaptionFont.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Text(String(format: "%.1f%%", allele.percentOfLocus * 100))
                .font(contentCaptionFont.monospacedDigit())
                .foregroundStyle(allele.isLowSupport ? Color(nsColor: .lungfishDanger) : .primary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func alleleLabelView(_ value: String, compact: Bool) -> some View {
        let label = AlleleLabel(value)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label.primary)
                    .font(
                        compact
                            ? contentCaptionFont.monospaced()
                            : contentMonospacedFont
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                if let badge = label.badge {
                    Text(badge)
                        .font(contentCaptionFont)
                        .foregroundStyle(.secondary)
                }
            }
            if !label.secondary.isEmpty {
                Text(label.secondary)
                    .font(contentCaptionFont.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(label.fullHeader)
    }

    private func compactAlleleLine(_ value: String, marker: String) -> some View {
        let isObserved = marker == "observed"
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(isObserved ? "✓" : "·")
                .font(contentCaptionFont.monospaced())
                .foregroundStyle(isObserved ? Color.green : .secondary)
            alleleLabelView(value, compact: true)
            if !isObserved {
                Text("[not observed]")
                    .font(contentCaptionFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func omittedHaplotypeGenotypes(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Omitted from haplotyping")
                .font(contentCaptionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("These retained genotype calls stayed in the run evidence but were below the haplotype thresholds recorded for this analysis.")
                .font(contentCaptionFont)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Genotype")
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Reads")
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text("% locus")
                    .font(contentCaptionFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            ForEach(evidence.omittedHaplotypeGenotypes) { genotype in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(genotype.genotype)
                            .font(contentMonospacedFont)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(genotype.reads)")
                            .font(contentCaptionFont.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.1f%%", genotype.percentOfLocus * 100))
                            .font(contentCaptionFont.monospacedDigit())
                            .foregroundStyle(Color(nsColor: .lungfishDanger))
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text(genotype.reason)
                        .font(contentCaptionFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func observedGenotypes(_ evidence: Evidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Observed genotypes (\(evidence.observedGenotypeCount))")
                .font(contentCaptionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(evidence.observedGenotypes.prefix(8), id: \.self) { gt in
                Text(gt)
                    .font(contentCaptionFont.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if evidence.observedGenotypes.count > 8 {
                Text("+ \(evidence.observedGenotypes.count - 8) more")
                    .font(contentCaptionFont)
                    .foregroundStyle(.tertiary)
            }
        }
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
            .font(contentCaptionFont.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.18))
            )
            .foregroundStyle(color)
    }

    var testingContentTypographyPointSizes: (body: CGFloat, caption: CGFloat) {
        (
            typographyModel.resolvedNSFont(for: .body).pointSize,
            typographyModel.resolvedNSFont(for: .caption).pointSize
        )
    }
}
