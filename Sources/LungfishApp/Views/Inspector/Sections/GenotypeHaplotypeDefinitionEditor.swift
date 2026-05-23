// GenotypeHaplotypeDefinitionEditor.swift - Editor sheet for user haplotype definitions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

/// Editor sheet for user-defined `GenotypeHaplotypeDefinitionSet` values.
/// Hosted in a sheet from the Audit lens (or a future Tools menu item).
///
/// **Why a sheet, not an inspector section:** definitions involve
/// multi-level editing (assay → set → locus → haplotype → diagnostic
/// alleles), which doesn't fit the narrow Inspector column. A modal sheet
/// gives the analyst room to work locus-by-locus.
struct GenotypeHaplotypeDefinitionEditor: View {
    @State private var draft: GenotypeHaplotypeDefinitionSet
    @State private var selectedLocusIndex: Int = 0
    @State private var selectedHaplotypeIndex: Int? = nil
    @State private var newAlleleText: String = ""
    let onSave: (GenotypeHaplotypeDefinitionSet) -> Void
    let onCancel: () -> Void

    init(
        draft: GenotypeHaplotypeDefinitionSet,
        onSave: @escaping (GenotypeHaplotypeDefinitionSet) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
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
                        draft = withDisplayName(draft, name: newValue)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
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
                Button(action: removeSelectedLocus) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .help("Remove the selected locus")
                .disabled(draft.locusDefinitions.isEmpty)
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
            Spacer()
            Button(action: addHaplotype) {
                Label("Add haplotype", systemImage: "plus")
            }
            .controlSize(.small)
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
                                colorTokenIndex: current.colorTokenIndex
                            )
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                Text("\(haplotype.diagnosticAlleles.count) diagnostic allele\(haplotype.diagnosticAlleles.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { removeHaplotype(locusIndex: selectedLocusIndex, hIndex: hIndex) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: .lungfishDanger))
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
                Button("Add", action: { addAllele(locusIndex: selectedLocusIndex, hIndex: hIndex) })
                    .controlSize(.small)
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
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(draft)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.displayName.isEmpty || draft.locusDefinitions.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Mutators

    private func withDisplayName(_ set: GenotypeHaplotypeDefinitionSet, name: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: set.id, assayID: set.assayID, displayName: name,
            speciesName: set.speciesName, speciesCode: set.speciesCode,
            prefix: set.prefix, locusDefinitions: set.locusDefinitions
        )
    }

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
            return GenotypeHaplotypeDefinition(
                name: current.name,
                diagnosticAlleles: alleles,
                colorTokenIndex: current.colorTokenIndex
            )
        }
        newAlleleText = ""
    }

    private func removeAllele(locusIndex: Int, hIndex: Int, allele: String) {
        updateHaplotype(locusIndex: locusIndex, hIndex: hIndex) { current in
            GenotypeHaplotypeDefinition(
                name: current.name,
                diagnosticAlleles: current.diagnosticAlleles.filter { $0 != allele },
                colorTokenIndex: current.colorTokenIndex
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
            prefix: set.prefix, locusDefinitions: loci
        )
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
