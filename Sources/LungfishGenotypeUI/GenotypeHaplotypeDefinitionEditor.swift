// GenotypeHaplotypeDefinitionEditor.swift - Editor sheet for user haplotype definitions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

/// Editor sheet for user-defined `GenotypeHaplotypeDefinitionSet` values.
/// Hosted in a sheet from the Audit lens (or a future Tools menu item).
///
/// **Why a sheet, not an inspector section:** definitions involve
/// multi-level editing (assay → set → locus → haplotype → diagnostic
/// alleles), which doesn't fit the narrow Inspector column. A modal sheet
/// gives the analyst room to work locus-by-locus.
public struct GenotypeHaplotypeDefinitionEditor: View {
    @State private var draft: GenotypeHaplotypeDefinitionSet
    @State private var selectedLocusIndex: Int = 0
    @State private var selectedHaplotypeIndex: Int? = nil
    @State private var newAlleleText: String = ""
    let isReadOnly: Bool
    let allowsIdentityEditing: Bool
    let allowsMetadataEditing: Bool
    /// When `true`, the editor surfaces a required Reference FASTA picker and
    /// blocks Save until one is chosen. Every definition is now a
    /// `.lungfishmhcref` bundle (FASTA + defs), so a saved definition always
    /// carries a reference FASTA.
    let requiresReferenceFASTA: Bool
    /// The project directory used to scan for `.lungfishref`/FASTA candidates.
    let projectURL: URL?
    @Binding var selectedReferenceURL: URL?
    let onSave: (GenotypeHaplotypeDefinitionSet) -> Void
    let onCancel: () -> Void

    public init(
        draft: GenotypeHaplotypeDefinitionSet,
        isReadOnly: Bool = false,
        allowsIdentityEditing: Bool = false,
        allowsMetadataEditing: Bool = false,
        requiresReferenceFASTA: Bool = false,
        projectURL: URL? = nil,
        selectedReferenceURL: Binding<URL?> = .constant(nil),
        onSave: @escaping (GenotypeHaplotypeDefinitionSet) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.isReadOnly = isReadOnly
        self.allowsIdentityEditing = allowsIdentityEditing
        self.allowsMetadataEditing = allowsMetadataEditing
        self.requiresReferenceFASTA = requiresReferenceFASTA
        self.projectURL = projectURL
        _selectedReferenceURL = selectedReferenceURL
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                locusSidebar
                    .frame(width: 180)
                Divider()
                haplotypeEditor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .foregroundStyle(Color(nsColor: .lungfishOrange))
                    .font(.title3)
                Text("Haplotype Definition")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let version = draft.schemaVersion {
                    Text("v\(version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .lungfishOrange).opacity(0.12))
                        )
                }
            }
            HStack(spacing: 8) {
                TextField("Display name", text: Binding(
                    get: { draft.displayName },
                    set: { newValue in
                        draft = GenotypeHaplotypeDefinitionDrafting.withDefinitionFields(draft, displayName: newValue)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .disabled(isReadOnly)
                Text("ID:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(draft.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                let locusCount = draft.locusDefinitions.count
                let haplotypeCount = draft.locusDefinitions.reduce(0) { $0 + $1.haplotypes.count }
                Text("\(locusCount) loci · \(haplotypeCount) haplotypes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if allowsMetadataEditing || allowsIdentityEditing {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Definition ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("definition-id", text: Binding(
                            get: { draft.id },
                            set: { draft = GenotypeHaplotypeDefinitionDrafting.withDefinitionFields(draft, id: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isReadOnly || !allowsIdentityEditing)
                    }
                    GridRow {
                        Text("Assay")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("assay-id", text: Binding(
                            get: { draft.assayID },
                            set: { draft = GenotypeHaplotypeDefinitionDrafting.withDefinitionFields(draft, assayID: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isReadOnly || !allowsMetadataEditing)
                    }
                    GridRow {
                        Text("Species")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Species name", text: Binding(
                                get: { draft.speciesName },
                                set: { draft = GenotypeHaplotypeDefinitionDrafting.withDefinitionFields(draft, speciesName: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            TextField("Code", text: Binding(
                                get: { draft.speciesCode },
                                set: { draft = GenotypeHaplotypeDefinitionDrafting.withDefinitionFields(draft, speciesCode: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            TextField("Allele prefix", text: Binding(
                                get: { draft.prefix },
                                set: { draft = GenotypeHaplotypeDefinitionDrafting.withDefinitionFields(draft, prefix: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        }
                        .disabled(isReadOnly || !allowsMetadataEditing)
                    }
                }
            }
            if let modified = draft.lastModified, !modified.isEmpty {
                Text("Last modified: \(modified)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .lungfishOrange).opacity(0.05)
        )
    }

    // MARK: - Locus sidebar

    private var locusSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedLocusIndex) {
                ForEach(Array(draft.locusDefinitions.enumerated()), id: \.offset) { index, locus in
                    HStack {
                        Text(locus.locus)
                            .font(.caption.monospaced())
                        Spacer()
                        Text("\(locus.haplotypes.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(index)
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 6) {
                Button(action: addLocus) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add a new locus")
                .disabled(isReadOnly)
                Button(action: removeSelectedLocus) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .help("Remove the selected locus")
                .disabled(isReadOnly || draft.locusDefinitions.isEmpty)
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Haplotype editor

    @ViewBuilder
    private var haplotypeEditor: some View {
        if draft.locusDefinitions.indices.contains(selectedLocusIndex) {
            let locus = draft.locusDefinitions[selectedLocusIndex]
            VStack(alignment: .leading, spacing: 12) {
                locusHeader(locus)
                Divider()
                haplotypeList(locus)
            }
            .padding(16)
        } else {
            VStack {
                Spacer()
                Text("Add a locus to begin defining haplotypes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func locusHeader(_ locus: GenotypeHaplotypeLocusDefinition) -> some View {
        HStack(spacing: 8) {
            Text("Locus")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Display locus", text: Binding(
                get: { locus.locus },
                set: { newValue in
                    updateLocus(at: selectedLocusIndex) { current in
                        GenotypeHaplotypeLocusDefinition(
                            locus: newValue,
                            sourceLocus: current.sourceLocus,
                            haplotypes: current.haplotypes
                        )
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            .disabled(isReadOnly)
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Source locus", text: Binding(
                get: { locus.sourceLocus },
                set: { newValue in
                    updateLocus(at: selectedLocusIndex) { current in
                        GenotypeHaplotypeLocusDefinition(
                            locus: current.locus,
                            sourceLocus: newValue,
                            haplotypes: current.haplotypes
                        )
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)
            .disabled(isReadOnly)
            Spacer()
            Button(action: addHaplotype) {
                Label("Add haplotype", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(isReadOnly)
        }
    }

    private func haplotypeList(_ locus: GenotypeHaplotypeLocusDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(locus.haplotypes.enumerated()), id: \.offset) { hIndex, haplotype in
                    haplotypeRow(hIndex: hIndex, haplotype: haplotype)
                }
            }
        }
    }

    private func haplotypeRow(hIndex: Int, haplotype: GenotypeHaplotypeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Haplotype name", text: Binding(
                    get: { haplotype.name },
                    set: { newValue in
                        updateHaplotype(locusIndex: selectedLocusIndex, hIndex: hIndex) { current in
                            GenotypeHaplotypeDefinition(
                                name: newValue,
                                diagnosticAlleles: current.diagnosticAlleles,
                                colorTokenIndex: current.colorTokenIndex,
                                minimumMatches: current.minimumMatches
                            )
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .disabled(isReadOnly)
                Text("\(haplotype.diagnosticAlleles.count) diagnostic allele\(haplotype.diagnosticAlleles.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Stepper(
                    "Requires \(haplotype.effectiveMinimumMatches) of \(haplotype.diagnosticAlleles.count)",
                    value: Binding(
                        get: { max(1, haplotype.effectiveMinimumMatches) },
                        set: { newValue in
                            updateHaplotype(locusIndex: selectedLocusIndex, hIndex: hIndex) { current in
                                GenotypeHaplotypeDefinitionDrafting.withMinimumMatches(
                                    current,
                                    minimumMatches: newValue
                                )
                            }
                        }
                    ),
                    in: 1...max(1, haplotype.diagnosticAlleles.count)
                )
                .controlSize(.small)
                .disabled(isReadOnly || haplotype.diagnosticAlleles.isEmpty)
                Spacer()
                Button(action: { removeHaplotype(locusIndex: selectedLocusIndex, hIndex: hIndex) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: .lungfishDanger))
                .disabled(isReadOnly)
            }
            // Diagnostic alleles as removable chips.
            FlowLayout(spacing: 4) {
                ForEach(haplotype.diagnosticAlleles, id: \.self) { allele in
                    HStack(spacing: 3) {
                        Text(allele)
                            .font(.caption.monospaced())
                        Button(action: { removeAllele(locusIndex: selectedLocusIndex, hIndex: hIndex, allele: allele) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isReadOnly)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
            }
            HStack(spacing: 4) {
                TextField("Add diagnostic allele", text: $newAlleleText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit {
                        addAllele(locusIndex: selectedLocusIndex, hIndex: hIndex)
                    }
                    .disabled(isReadOnly)
                Button("Add", action: { addAllele(locusIndex: selectedLocusIndex, hIndex: hIndex) })
                    .controlSize(.small)
                    .disabled(isReadOnly)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        let validationMessages = GenotypeHaplotypeDefinitionDrafting.validationMessages(for: draft)
        let missingReferenceFASTA = requiresReferenceFASTA && selectedReferenceURL == nil
        return VStack(alignment: .leading, spacing: 8) {
            if requiresReferenceFASTA {
                ReferenceSequencePickerView(
                    projectURL: projectURL,
                    selectedReferenceURL: $selectedReferenceURL
                )
            }
            HStack {
                if let firstMessage = validationMessages.first {
                    Text(firstMessage)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .lungfishDanger))
                        .lineLimit(2)
                } else if missingReferenceFASTA {
                    Text("Choose a reference FASTA to save this definition as a bundle.")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .lungfishDanger))
                        .lineLimit(2)
                }
                Spacer()
                Button(isReadOnly ? "Close" : "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if !isReadOnly {
                    Button("Save") {
                        onSave(draft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draft.displayName.isEmpty
                            || draft.locusDefinitions.isEmpty
                            || !validationMessages.isEmpty
                            || missingReferenceFASTA
                    )
                }
            }
        }
        .padding(12)
    }

    // MARK: - Mutators

    private func addLocus() {
        var loci = draft.locusDefinitions
        let nextIndex = loci.count + 1
        loci.append(GenotypeHaplotypeLocusDefinition(
            locus: "MHC-NEW-\(nextIndex)",
            sourceLocus: "NEW-\(nextIndex)",
            haplotypes: []
        ))
        draft = replacingLoci(draft, loci: loci)
        selectedLocusIndex = loci.count - 1
    }

    private func removeSelectedLocus() {
        guard draft.locusDefinitions.indices.contains(selectedLocusIndex) else { return }
        var loci = draft.locusDefinitions
        loci.remove(at: selectedLocusIndex)
        draft = replacingLoci(draft, loci: loci)
        selectedLocusIndex = max(0, min(selectedLocusIndex, loci.count - 1))
    }

    private func addHaplotype() {
        updateLocus(at: selectedLocusIndex) { current in
            var haplotypes = current.haplotypes
            haplotypes.append(GenotypeHaplotypeDefinition(
                name: "Haplotype \(haplotypes.count + 1)",
                diagnosticAlleles: []
            ))
            return GenotypeHaplotypeLocusDefinition(
                locus: current.locus,
                sourceLocus: current.sourceLocus,
                haplotypes: haplotypes
            )
        }
    }

    private func removeHaplotype(locusIndex: Int, hIndex: Int) {
        updateLocus(at: locusIndex) { current in
            var haplotypes = current.haplotypes
            guard haplotypes.indices.contains(hIndex) else { return current }
            haplotypes.remove(at: hIndex)
            return GenotypeHaplotypeLocusDefinition(
                locus: current.locus,
                sourceLocus: current.sourceLocus,
                haplotypes: haplotypes
            )
        }
    }

    private func addAllele(locusIndex: Int, hIndex: Int) {
        let trimmed = newAlleleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateHaplotype(locusIndex: locusIndex, hIndex: hIndex) { current in
            var alleles = current.diagnosticAlleles
            guard !alleles.contains(trimmed) else { return current }
            alleles.append(trimmed)
            return GenotypeHaplotypeDefinitionDrafting.withDiagnosticAlleles(current, alleles: alleles)
        }
        newAlleleText = ""
    }

    private func removeAllele(locusIndex: Int, hIndex: Int, allele: String) {
        updateHaplotype(locusIndex: locusIndex, hIndex: hIndex) { current in
            GenotypeHaplotypeDefinitionDrafting.withDiagnosticAlleles(
                current,
                alleles: current.diagnosticAlleles.filter { $0 != allele }
            )
        }
    }

    private func updateLocus(
        at index: Int,
        _ transform: (GenotypeHaplotypeLocusDefinition) -> GenotypeHaplotypeLocusDefinition
    ) {
        guard draft.locusDefinitions.indices.contains(index) else { return }
        var loci = draft.locusDefinitions
        loci[index] = transform(loci[index])
        draft = replacingLoci(draft, loci: loci)
    }

    private func updateHaplotype(
        locusIndex: Int, hIndex: Int,
        _ transform: (GenotypeHaplotypeDefinition) -> GenotypeHaplotypeDefinition
    ) {
        updateLocus(at: locusIndex) { current in
            var haplotypes = current.haplotypes
            guard haplotypes.indices.contains(hIndex) else { return current }
            haplotypes[hIndex] = transform(haplotypes[hIndex])
            return GenotypeHaplotypeLocusDefinition(
                locus: current.locus,
                sourceLocus: current.sourceLocus,
                haplotypes: haplotypes
            )
        }
    }

    private func replacingLoci(
        _ set: GenotypeHaplotypeDefinitionSet,
        loci: [GenotypeHaplotypeLocusDefinition]
    ) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: set.id, assayID: set.assayID, displayName: set.displayName,
            speciesName: set.speciesName, speciesCode: set.speciesCode,
            prefix: set.prefix, locusDefinitions: loci,
            schemaVersion: set.schemaVersion,
            lastModified: set.lastModified,
            changeNote: set.changeNote
        )
    }
}

enum GenotypeHaplotypeDefinitionDrafting {
    static func withDisplayName(
        _ set: GenotypeHaplotypeDefinitionSet,
        name: String
    ) -> GenotypeHaplotypeDefinitionSet {
        withDefinitionFields(set, displayName: name)
    }

    static func withDefinitionFields(
        _ set: GenotypeHaplotypeDefinitionSet,
        id: String? = nil,
        assayID: String? = nil,
        displayName: String? = nil,
        speciesName: String? = nil,
        speciesCode: String? = nil,
        prefix: String? = nil
    ) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id ?? set.id,
            assayID: assayID ?? set.assayID,
            displayName: displayName ?? set.displayName,
            speciesName: speciesName ?? set.speciesName,
            speciesCode: speciesCode ?? set.speciesCode,
            prefix: prefix ?? set.prefix,
            locusDefinitions: set.locusDefinitions,
            schemaVersion: set.schemaVersion,
            lastModified: set.lastModified,
            changeNote: set.changeNote
        )
    }

    static func renamingHaplotype(
        in set: GenotypeHaplotypeDefinitionSet,
        locusIndex: Int,
        haplotypeIndex: Int,
        name: String
    ) -> GenotypeHaplotypeDefinitionSet {
        replacingHaplotype(in: set, locusIndex: locusIndex, haplotypeIndex: haplotypeIndex) {
            GenotypeHaplotypeDefinition(
                name: name,
                diagnosticAlleles: $0.diagnosticAlleles,
                colorTokenIndex: $0.colorTokenIndex,
                minimumMatches: $0.minimumMatches
            )
        }
    }

    static func withDiagnosticAlleles(
        _ haplotype: GenotypeHaplotypeDefinition,
        alleles: [String]
    ) -> GenotypeHaplotypeDefinition {
        GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: alleles,
            colorTokenIndex: haplotype.colorTokenIndex,
            minimumMatches: clampedMinimumMatches(haplotype.minimumMatches, alleleCount: alleles.count)
        )
    }

    static func withMinimumMatches(
        _ haplotype: GenotypeHaplotypeDefinition,
        minimumMatches: Int
    ) -> GenotypeHaplotypeDefinition {
        let clamped = clampedMinimumMatches(minimumMatches, alleleCount: haplotype.diagnosticAlleles.count)
        let stored = clamped == haplotype.diagnosticAlleles.count ? nil : clamped
        return GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: haplotype.diagnosticAlleles,
            colorTokenIndex: haplotype.colorTokenIndex,
            minimumMatches: stored
        )
    }

    static func validationMessages(for set: GenotypeHaplotypeDefinitionSet) -> [String] {
        var messages: [String] = []
        let trimmedName = set.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            messages.append("Definition name is required.")
        }
        if set.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Definition ID is required.")
        }
        if set.assayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Assay ID is required.")
        }
        if set.speciesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || set.speciesCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Species name and code are required.")
        }
        if set.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Allele prefix is required.")
        }
        let locusNames = set.locusDefinitions.map { $0.locus.trimmingCharacters(in: .whitespacesAndNewlines) }
        if locusNames.contains(where: \.isEmpty) {
            messages.append("Locus names are required.")
        }
        if hasDuplicates(locusNames.filter { !$0.isEmpty }) {
            messages.append("Duplicate locus names are not allowed.")
        }
        for locus in set.locusDefinitions {
            let haplotypeNames = locus.haplotypes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if haplotypeNames.contains(where: \.isEmpty) {
                messages.append("Haplotype name is required.")
            }
            if hasDuplicates(haplotypeNames.filter { !$0.isEmpty }) {
                messages.append("Duplicate haplotype names are not allowed within \(locus.locus).")
            }
            if locus.haplotypes.contains(where: { $0.diagnosticAlleles.isEmpty }) {
                messages.append("Each haplotype needs at least one diagnostic allele.")
            }
        }
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    private static func replacingHaplotype(
        in set: GenotypeHaplotypeDefinitionSet,
        locusIndex: Int,
        haplotypeIndex: Int,
        transform: (GenotypeHaplotypeDefinition) -> GenotypeHaplotypeDefinition
    ) -> GenotypeHaplotypeDefinitionSet {
        guard set.locusDefinitions.indices.contains(locusIndex) else { return set }
        var loci = set.locusDefinitions
        var haplotypes = loci[locusIndex].haplotypes
        guard haplotypes.indices.contains(haplotypeIndex) else { return set }
        haplotypes[haplotypeIndex] = transform(haplotypes[haplotypeIndex])
        loci[locusIndex] = GenotypeHaplotypeLocusDefinition(
            locus: loci[locusIndex].locus,
            sourceLocus: loci[locusIndex].sourceLocus,
            haplotypes: haplotypes
        )
        return GenotypeHaplotypeDefinitionSet(
            id: set.id,
            assayID: set.assayID,
            displayName: set.displayName,
            speciesName: set.speciesName,
            speciesCode: set.speciesCode,
            prefix: set.prefix,
            locusDefinitions: loci,
            schemaVersion: set.schemaVersion,
            lastModified: set.lastModified,
            changeNote: set.changeNote
        )
    }

    private static func clampedMinimumMatches(_ minimumMatches: Int?, alleleCount: Int) -> Int? {
        guard let minimumMatches else { return nil }
        return clampedMinimumMatchesValue(minimumMatches, alleleCount: alleleCount)
    }

    private static func clampedMinimumMatchesValue(_ minimumMatches: Int, alleleCount: Int) -> Int {
        max(1, min(minimumMatches, max(1, alleleCount)))
    }

    private static func hasDuplicates(_ values: [String]) -> Bool {
        var seen = Set<String>()
        for value in values {
            if !seen.insert(value).inserted { return true }
        }
        return false
    }
}

/// Minimal flow-layout container — wraps chips to multiple lines without
/// needing iOS 16+ `Layout` protocol on macOS 13 builds. The Definition
/// editor uses this for diagnostic-allele chips.
private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // SwiftUI's `Layout` is available on macOS 13+; the app targets
        // macOS 26 so this is safe. The layout simply wraps subviews
        // when they don't fit the available width.
        if #available(macOS 13.0, *) {
            FlowLayoutContainer(spacing: spacing) { content() }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}

@available(macOS 13.0, *)
private struct FlowLayoutContainer: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + width, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
