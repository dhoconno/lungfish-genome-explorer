// SelectionSection.swift - Annotation/selection editing inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import LungfishCore
import LungfishIO

/// Mode for applying color changes.
public enum ColorApplyMode: String, CaseIterable, Identifiable {
    case thisOnly = "This Only"
    case allOfType = "All of Type"

    public var id: String { rawValue }
}

/// View model for the selection section.
///
/// Manages the state of the currently selected annotation for editing.
@Observable
@MainActor
public final class SelectionSectionViewModel {
    /// The currently selected annotation, if any
    public var selectedAnnotation: SequenceAnnotation?

    /// Editable name binding
    public var name: String = ""

    /// Editable annotation type
    public var type: AnnotationType = .region

    /// Editable color
    public var color: Color = .blue

    /// Editable notes
    public var notes: String = ""

    /// Mode for applying color changes
    public var colorApplyMode: ColorApplyMode = .thisOnly

    /// Flag to prevent onChange handlers from firing during programmatic updates.
    /// Marked with @ObservationIgnored since this flag should not trigger view updates.
    @ObservationIgnored
    public var isUpdatingFromSelection: Bool = false

    /// Callback when annotation is updated
    public var onAnnotationUpdated: ((SequenceAnnotation) -> Void)?

    /// Callback when annotation is deleted
    public var onAnnotationDeleted: ((UUID) -> Void)?

    /// Callback when color should be applied to all annotations of a type
    public var onApplyColorToAllOfType: ((AnnotationType, AnnotationColor) -> Void)?

    /// Callback to create a new annotation from current viewer selection.
    public var onAddAnnotationRequested: (() -> Void)?

    /// Callback to show/compute translation in the viewer for a CDS annotation.
    public var onShowTranslation: ((SequenceAnnotation) -> Void)?

    /// Callback to extract sequence (presents extraction sheet).
    public var onExtractSequence: ((SequenceAnnotation) -> Void)?

    /// Callback to copy annotation as FASTA.
    public var onCopyAsFASTA: ((SequenceAnnotation) -> Void)?

    /// Callback to copy CDS translation as FASTA.
    public var onCopyTranslationAsFASTA: ((SequenceAnnotation) -> Void)?

    /// Callback to copy annotation's raw sequence to clipboard.
    public var onCopySequence: ((SequenceAnnotation) -> Void)?

    /// Callback to copy annotation's reverse complement to clipboard.
    public var onCopyReverseComplement: ((SequenceAnnotation) -> Void)?

    /// Callback to zoom the viewer to an annotation.
    public var onZoomToAnnotation: ((SequenceAnnotation) -> Void)?

    /// Whether the translation track is currently visible in the viewer.
    public var isTranslationVisible: Bool = false

    // MARK: - Translation Fields

    /// Full amino acid translation (not truncated), from GenBank qualifier or computed.
    public var fullTranslation: String?

    // MARK: - Enrichment Fields (read-only, from qualifiers + SQLite)

    /// All displayable qualifier key-value pairs.
    public var qualifierPairs: [(key: String, value: String)] = []

    /// Parsed database cross-references with clickable URLs.
    public var dbxrefLinks: [(database: String, id: String, url: URL?)] = []

    /// Optional reference to the annotation database for enrichment lookups.
    @ObservationIgnored
    public var annotationDatabase: AnnotationDatabase? {
        didSet {
            // If a selection already exists, refresh enrichment immediately when
            // database wiring changes (e.g. index build completes after selection).
            if let selectedAnnotation {
                extractEnrichment(from: selectedAnnotation)
            }
        }
    }

    /// Reference bundle for computing CDS translations on-the-fly (bundle mode).
    @ObservationIgnored
    public var referenceBundle: ReferenceBundle?

    public init() {}

    /// Computes an amino acid translation for the given CDS annotation from the underlying sequence.
    ///
    /// Uses the reference bundle's synchronous sequence fetch to extract nucleotides
    /// for each CDS interval and translates them via `TranslationEngine.translateCDS`.
    ///
    /// - Parameter annotation: The CDS/mRNA annotation to translate.
    /// - Returns: The protein string, or nil if translation fails.
    public func computeTranslation(for annotation: SequenceAnnotation) -> String? {
        guard let bundle = referenceBundle else { return nil }

        let sequenceProvider: (Int, Int) -> String? = { start, end in
            let region = GenomicRegion(
                chromosome: annotation.chromosome ?? bundle.chromosomeNames.first ?? "",
                start: start, end: end
            )
            return try? bundle.fetchSequenceSync(region: region)
        }

        guard let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: sequenceProvider
        ) else { return nil }

        return result.protein
    }

    /// Updates the view model with a new annotation selection.
    ///
    /// - Parameter annotation: The newly selected annotation, or nil for no selection
    public func select(annotation: SequenceAnnotation?) {
        // Set flag to prevent onChange handlers from firing during this update
        isUpdatingFromSelection = true
        defer { isUpdatingFromSelection = false }
        let previousAnnotationID = selectedAnnotation?.id

        // @Observable automatically tracks property changes, no manual refresh needed
        selectedAnnotation = annotation
        if let annotation = annotation {
            // Reset translation visibility when switching to a different annotation.
            if previousAnnotationID != annotation.id {
                isTranslationVisible = false
            }
            name = annotation.name
            type = annotation.type
            notes = annotation.note ?? ""

            // Set color from annotation or use type's default
            let annotationColor = annotation.color ?? annotation.type.defaultColor
            color = Color(
                red: annotationColor.red,
                green: annotationColor.green,
                blue: annotationColor.blue,
                opacity: annotationColor.alpha
            )

            // Reset apply mode when selecting a new annotation
            colorApplyMode = .thisOnly

            // Extract enrichment from qualifiers["extra"] (GFF3 attributes)
            extractEnrichment(from: annotation)
        } else {
            // Reset all properties on deselection to prevent stale values
            name = ""
            type = .region
            notes = ""
            color = .blue
            colorApplyMode = .thisOnly
            qualifierPairs = []
            dbxrefLinks = []
            fullTranslation = nil
            isTranslationVisible = false
        }
    }

    /// Extracts all qualifier data from the annotation and optional SQLite database.
    ///
    /// Merges qualifiers from two sources:
    /// 1. `qualifiers["extra"]` on the annotation (BED extra columns / GFF3 attributes)
    /// 2. SQLite annotation database `attributes` column (if database is available)
    ///
    /// Internal keys (`score`, `extra`) and very long values (`translation`) are excluded.
    /// `db_xref`/`Dbxref` entries are parsed into clickable links.
    private func extractEnrichment(from annotation: SequenceAnnotation) {
        qualifierPairs = []
        dbxrefLinks = []
        fullTranslation = nil

        var parsed: [String: String] = [:]

        // Source 1: qualifiers["extra"] from the annotation object
        if let extraStr = annotation.qualifier("extra") {
            let attrString: String
            if extraStr.contains("\t") {
                let parts = extraStr.split(separator: "\t", maxSplits: 1)
                attrString = parts.count > 1 ? String(parts[1]) : extraStr
            } else {
                attrString = extraStr
            }
            parsed = LungfishIO.AnnotationDatabase.parseAttributes(attrString)
        }

        // Source 2: SQLite annotation database (richer data, if available)
        if let db = annotationDatabase {
            let record = db.lookupAnnotation(
                name: annotation.name,
                chromosome: annotation.chromosome ?? "",
                start: annotation.start,
                end: annotation.end
            )
            if let attrs = record?.attributes, !attrs.isEmpty {
                let dbParsed = LungfishIO.AnnotationDatabase.parseAttributes(attrs)
                // Merge: database values supplement annotation values
                for (key, value) in dbParsed where parsed[key] == nil {
                    parsed[key] = value
                }
            }
        }

        guard !parsed.isEmpty else { return }

        // Keys to exclude from display
        let excludedKeys: Set<String> = ["score", "extra", "_lf_raw_feature_type"]

        // Build qualifier pairs (excluding internal keys and very long values)
        let displayOrder = [
            "gene", "product", "description", "gene_biotype", "protein_id",
            "transcript_id", "note", "function",
        ]

        // Ordered keys first, then remaining alphabetically
        var orderedKeys: [String] = []
        for key in displayOrder where parsed[key] != nil {
            orderedKeys.append(key)
        }
        let remaining = parsed.keys.sorted().filter {
            !displayOrder.contains($0) && !excludedKeys.contains($0)
                && $0 != "db_xref" && $0 != "Dbxref"
        }
        orderedKeys.append(contentsOf: remaining)

        for key in orderedKeys {
            guard let value = parsed[key] else { continue }
            if key == "translation" {
                // Store full translation separately for the dedicated Translation section
                fullTranslation = value
                // Show truncated preview in qualifier list
                if value.count > 80 {
                    qualifierPairs.append((key: Self.displayKeyName(key), value: String(value.prefix(80)) + "..."))
                } else {
                    qualifierPairs.append((key: Self.displayKeyName(key), value: value))
                }
            } else {
                qualifierPairs.append((key: Self.displayKeyName(key), value: value))
            }
        }

        // Parse db_xref / Dbxref into clickable links
        let dbxrefRaw = parsed["db_xref"] ?? parsed["Dbxref"] ?? ""
        if !dbxrefRaw.isEmpty {
            // Can be comma-separated: "GeneID:12345,UniProt:P12345"
            let refs = dbxrefRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            for ref in refs {
                let parts = ref.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let database = String(parts[0])
                    let id = String(parts[1])
                    dbxrefLinks.append((database: database, id: id, url: Self.makeDbxrefURL(database: database, id: id)))
                } else {
                    // No colon — show as-is
                    dbxrefLinks.append((database: ref, id: "", url: nil))
                }
            }
        }
    }

    /// Maps qualifier key names to human-readable display names.
    static func displayKeyName(_ key: String) -> String {
        switch key {
        case "gene": return "Gene"
        case "product": return "Product"
        case "description": return "Description"
        case "gene_biotype": return "Biotype"
        case "protein_id": return "Protein ID"
        case "transcript_id": return "Transcript ID"
        case "note": return "Note"
        case "function": return "Function"
        case "codon_start": return "Codon Start"
        case "transl_table": return "Translation Table"
        case "translation": return "Translation"
        case "organism": return "Organism"
        case "mol_type": return "Molecule Type"
        default: return key
        }
    }

    /// Generates a URL for a database cross-reference.
    static func makeDbxrefURL(database: String, id: String) -> URL? {
        switch database {
        case "GeneID":
            return URL(string: "https://www.ncbi.nlm.nih.gov/gene/\(id)")
        case "UniProt", "UniProtKB/Swiss-Prot", "UniProtKB/TrEMBL":
            return URL(string: "https://www.uniprot.org/uniprot/\(id)")
        case "taxon":
            return URL(string: "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(id)")
        case "InterPro":
            return URL(string: "https://www.ebi.ac.uk/interpro/entry/InterPro/\(id)/")
        case "PFAM", "Pfam":
            return URL(string: "https://www.ebi.ac.uk/interpro/entry/pfam/\(id)/")
        case "GO":
            return URL(string: "https://amigo.geneontology.org/amigo/term/GO:\(id)")
        case "PDB":
            return URL(string: "https://www.rcsb.org/structure/\(id)")
        case "HGNC":
            return URL(string: "https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/HGNC:\(id)")
        case "MGI":
            return URL(string: "https://www.informatics.jax.org/marker/MGI:\(id)")
        case "MIM", "OMIM":
            return URL(string: "https://www.omim.org/entry/\(id)")
        default:
            return nil
        }
    }

    /// Commits current edits to the annotation.
    func commitChanges() {
        guard var annotation = selectedAnnotation else { return }

        annotation.name = name
        annotation.type = type
        annotation.note = notes.isEmpty ? nil : notes

        // Convert SwiftUI Color to AnnotationColor
        if let annotationColor = extractAnnotationColor(from: color) {
            annotation.color = annotationColor
        }

        selectedAnnotation = annotation
        onAnnotationUpdated?(annotation)
    }

    /// Commits color change, respecting the apply mode.
    func commitColorChange() {
        guard var annotation = selectedAnnotation else { return }

        // Convert SwiftUI Color to AnnotationColor
        guard let annotationColor = extractAnnotationColor(from: color) else { return }

        annotation.color = annotationColor
        selectedAnnotation = annotation

        switch colorApplyMode {
        case .thisOnly:
            // Update just this annotation
            onAnnotationUpdated?(annotation)

        case .allOfType:
            // Update this annotation
            onAnnotationUpdated?(annotation)
            // Also notify to update all annotations of this type
            onApplyColorToAllOfType?(annotation.type, annotationColor)
        }
    }

    /// Extracts an AnnotationColor from a SwiftUI Color.
    ///
    /// Uses NSColor conversion as a fallback for colors that don't have a direct CGColor
    /// representation (like system colors or dynamic colors).
    private func extractAnnotationColor(from color: Color) -> AnnotationColor? {
        // Try direct CGColor extraction first
        if let cgColor = color.cgColor,
           let components = cgColor.components,
           components.count >= 3 {
            return AnnotationColor(
                red: components[0],
                green: components[1],
                blue: components[2],
                alpha: components.count > 3 ? components[3] : 1.0
            )
        }

        // Fallback: convert through NSColor for system/dynamic colors
        let nsColor = NSColor(color)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            // Final fallback: try deviceRGB color space
            guard let deviceColor = nsColor.usingColorSpace(.deviceRGB) else {
                return nil
            }
            return AnnotationColor(
                red: deviceColor.redComponent,
                green: deviceColor.greenComponent,
                blue: deviceColor.blueComponent,
                alpha: deviceColor.alphaComponent
            )
        }
        return AnnotationColor(
            red: rgbColor.redComponent,
            green: rgbColor.greenComponent,
            blue: rgbColor.blueComponent,
            alpha: rgbColor.alphaComponent
        )
    }

    /// Deletes the current annotation.
    func deleteAnnotation() {
        guard let annotation = selectedAnnotation else { return }
        onAnnotationDeleted?(annotation.id)
        select(annotation: nil)
    }
}

// MARK: - SelectionSection

/// SwiftUI view for editing annotation/selection details.
///
/// Displays editable fields for the selected annotation including name, type,
/// color, and notes. Shows a placeholder message when no annotation is selected.
public struct SelectionSection: View {
    @Bindable var viewModel: SelectionSectionViewModel
    @State private var isExpanded = true
    @State private var showDeleteConfirmation = false
    @State private var isTranslationExpanded = false

    public init(viewModel: SelectionSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if viewModel.selectedAnnotation != nil {
                annotationEditor
            } else {
                noSelectionView
            }
        } label: {
            Text("Selection")
                .font(.headline)
        }
    }

    // MARK: - Annotation Editor

    @ViewBuilder
    private var annotationEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Annotation name", text: $viewModel.name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.name) { _, _ in
                        guard !viewModel.isUpdatingFromSelection else { return }
                        viewModel.commitChanges()
                    }
            }

            // Type picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Type")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Type", selection: $viewModel.type) {
                    ForEach(AnnotationType.allCases, id: \.self) { type in
                        Text(type.displayName)
                            .tag(type)
                    }
                }
                .labelsHidden()
                .onChange(of: viewModel.type) { _, _ in
                    guard !viewModel.isUpdatingFromSelection else { return }
                    viewModel.commitChanges()
                }
            }

            // Color picker with apply mode
            VStack(alignment: .leading, spacing: 4) {
                Text("Color")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ColorPicker("Annotation Color", selection: $viewModel.color, supportsOpacity: true)
                        .labelsHidden()
                        .onChange(of: viewModel.color) { _, _ in
                            guard !viewModel.isUpdatingFromSelection else { return }
                            viewModel.commitColorChange()
                        }

                    Spacer()
                }

                // Apply mode picker
                Picker("Apply to", selection: $viewModel.colorApplyMode) {
                    ForEach(ColorApplyMode.allCases) { mode in
                        Text(mode == .allOfType ? "All \(viewModel.type.displayName)" : mode.rawValue)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose whether to apply color changes to just this annotation or all annotations of the same type")
            }

            // Notes editor
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.notes)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .onChange(of: viewModel.notes) { _, _ in
                        guard !viewModel.isUpdatingFromSelection else { return }
                        viewModel.commitChanges()
                    }
            }

            // Location info (read-only)
            if let annotation = viewModel.selectedAnnotation {
                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    if let chrom = annotation.chromosome {
                        LabeledContent("Chromosome", value: chrom)
                    }
                    LabeledContent("Start", value: "\(annotation.start)")
                    LabeledContent("End", value: "\(annotation.end)")
                    LabeledContent("Length", value: "\(annotation.totalLength) bp")
                    let strandLabel: String = switch annotation.strand {
                    case .forward: "Forward (+)"
                    case .reverse: "Reverse (-)"
                    case .unknown: "Unknown"
                    }
                    LabeledContent("Strand", value: strandLabel)
                    if annotation.isDiscontinuous {
                        LabeledContent("Intervals", value: "\(annotation.intervals.count)")
                    }
                }
                .font(.callout)

                // Qualifier details (from GFF3 / GenBank / SQLite)
                if !viewModel.qualifierPairs.isEmpty || !viewModel.dbxrefLinks.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.qualifierPairs.enumerated()), id: \.offset) { _, pair in
                            if pair.value.count > 60 {
                                // Long values get a stacked layout
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pair.key)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(pair.value)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            } else {
                                LabeledContent(pair.key, value: pair.value)
                                    .font(.callout)
                            }
                        }

                        // Database cross-references with clickable links
                        if !viewModel.dbxrefLinks.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("References")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(viewModel.dbxrefLinks.enumerated()), id: \.offset) { _, link in
                                    if let url = link.url {
                                        Link(destination: url) {
                                            HStack(spacing: 4) {
                                                Text(link.database)
                                                    .foregroundStyle(.secondary)
                                                Text(link.id)
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.caption2)
                                            }
                                            .font(.callout)
                                        }
                                    } else {
                                        HStack(spacing: 4) {
                                            Text(link.database)
                                                .foregroundStyle(.secondary)
                                            if !link.id.isEmpty {
                                                Text(link.id)
                                            }
                                        }
                                        .font(.callout)
                                        .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Extraction actions
            if let annotation = viewModel.selectedAnnotation {
                extractionButtons(for: annotation)
            }

            // Translation section (for CDS/mRNA annotations or annotations with stored translations)
            if viewModel.type == .cds || viewModel.type == .mRNA || viewModel.fullTranslation != nil {
                translationSection
            }

            Divider()
                .padding(.vertical, 4)

            // Delete button
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Annotation", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .confirmationDialog(
                "Delete Annotation",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    viewModel.deleteAnnotation()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete \"\(viewModel.name)\"? This action cannot be undone.")
            }
        }
        .padding(.top, 8)
    }

    // MARK: - No Selection View

    @ViewBuilder
    private var noSelectionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "selection.pin.in.out")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No Selection")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Select an annotation to edit its properties")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.onAddAnnotationRequested?()
            } label: {
                Label("Add Annotation from Selection...", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Extraction Buttons

    @ViewBuilder
    private func extractionButtons(for annotation: SequenceAnnotation) -> some View {
        Divider()
            .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 6) {
            Text("Sequence")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                viewModel.onCopySequence?(annotation)
            } label: {
                Label("Copy Sequence", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button {
                viewModel.onCopyReverseComplement?(annotation)
            } label: {
                Label("Copy Reverse Complement", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button {
                viewModel.onCopyAsFASTA?(annotation)
            } label: {
                Label("Copy as FASTA", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if annotation.type == .cds {
                Button {
                    viewModel.onCopyTranslationAsFASTA?(annotation)
                } label: {
                    Label("Copy Translation as FASTA", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Button {
                viewModel.onExtractSequence?(annotation)
            } label: {
                Label("Extract Sequence\u{2026}", systemImage: "scissors")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()
                .padding(.vertical, 2)

            Button {
                viewModel.onZoomToAnnotation?(annotation)
            } label: {
                Label("Zoom to Annotation", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    // MARK: - Translation Section

    @ViewBuilder
    private var translationSection: some View {
        Divider()
            .padding(.vertical, 4)

        DisclosureGroup("Translation", isExpanded: $isTranslationExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let translation = viewModel.fullTranslation {
                    // Full amino acid sequence, scrollable and selectable
                    ScrollView {
                        Text(translation)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Copy button
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translation, forType: .string)
                    } label: {
                        Label("Copy Translation", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else if viewModel.referenceBundle != nil,
                          let annotation = viewModel.selectedAnnotation,
                          (viewModel.type == .cds || viewModel.type == .mRNA) {
                    // CDS/mRNA without stored translation — offer to compute from bundle sequence
                    Button {
                        if let computed = viewModel.computeTranslation(for: annotation) {
                            viewModel.fullTranslation = computed
                        }
                    } label: {
                        Label("Compute from Sequence", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Text("No stored translation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // "Translate in Viewer" toggle
                if let annotation = viewModel.selectedAnnotation {
                    Button {
                        // Auto-compute translation if not yet available
                        if viewModel.fullTranslation == nil {
                            viewModel.fullTranslation = viewModel.computeTranslation(for: annotation)
                        }
                        viewModel.onShowTranslation?(annotation)
                    } label: {
                        Label(
                            viewModel.isTranslationVisible ? "Hide in Viewer" : "Show in Viewer",
                            systemImage: viewModel.isTranslationVisible ? "eye.slash" : "eye"
                        )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .font(.subheadline)
    }
}

// MARK: - AnnotationType Extension

extension AnnotationType {
    /// Human-readable display name for the annotation type.
    var displayName: String {
        switch self {
        case .gene: return "Gene"
        case .mRNA: return "mRNA"
        case .transcript: return "Transcript"
        case .exon: return "Exon"
        case .intron: return "Intron"
        case .cds: return "CDS"
        case .utr5: return "5' UTR"
        case .utr3: return "3' UTR"
        case .promoter: return "Promoter"
        case .enhancer: return "Enhancer"
        case .silencer: return "Silencer"
        case .terminator: return "Terminator"
        case .polyASignal: return "PolyA Signal"
        case .regulatory: return "Regulatory"
        case .ncRNA: return "ncRNA"
        case .primer: return "Primer"
        case .primerPair: return "Primer Pair"
        case .amplicon: return "Amplicon"
        case .restrictionSite: return "Restriction Site"
        case .snp: return "SNP"
        case .variation: return "Variation"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .repeatRegion: return "Repeat Region"
        case .stem_loop: return "Stem Loop"
        case .misc_feature: return "Misc Feature"
        case .mat_peptide: return "Mature Peptide"
        case .sig_peptide: return "Signal Peptide"
        case .transit_peptide: return "Transit Peptide"
        case .misc_binding: return "Misc Binding"
        case .protein_bind: return "Protein Binding"
        case .contig: return "Contig"
        case .gap: return "Gap"
        case .scaffold: return "Scaffold"
        case .region: return "Region"
        case .source: return "Source"
        case .custom: return "Custom"
        // FASTQ read-level annotations
        case .barcode5p: return "Barcode (5')"
        case .barcode3p: return "Barcode (3')"
        case .adapter5p: return "Adapter (5')"
        case .adapter3p: return "Adapter (3')"
        case .primer5p: return "Primer (5')"
        case .primer3p: return "Primer (3')"
        case .trimQuality: return "Quality Trim"
        case .trimFixed: return "Fixed Trim"
        case .orientMarker: return "Orientation"
        case .umiRegion: return "UMI"
        case .contaminantMatch: return "Contaminant"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SelectionSection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                // With selection
                SelectionSection(viewModel: {
                    let vm = SelectionSectionViewModel()
                    vm.select(annotation: SequenceAnnotation(
                        type: .gene,
                        name: "BRCA1",
                        start: 1000,
                        end: 5000,
                        strand: .forward,
                        note: "Breast cancer susceptibility gene"
                    ))
                    return vm
                }())

                Divider()

                // Without selection
                SelectionSection(viewModel: SelectionSectionViewModel())
            }
            .padding()
        }
        .frame(width: 280, height: 600)
    }
}
#endif
