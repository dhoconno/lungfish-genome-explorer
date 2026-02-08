// SelectionSection.swift - Annotation/selection editing inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import LungfishCore

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

    public init() {}

    /// Updates the view model with a new annotation selection.
    ///
    /// - Parameter annotation: The newly selected annotation, or nil for no selection
    public func select(annotation: SequenceAnnotation?) {
        // Set flag to prevent onChange handlers from firing during this update
        isUpdatingFromSelection = true
        defer { isUpdatingFromSelection = false }

        // @Observable automatically tracks property changes, no manual refresh needed
        selectedAnnotation = annotation
        if let annotation = annotation {
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
        } else {
            // Reset all properties on deselection to prevent stale values
            name = ""
            type = .region
            notes = ""
            color = .blue
            colorApplyMode = .thisOnly
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
        selectedAnnotation = nil
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
            Label("Selection", systemImage: "selection.pin.in.out")
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
                    LabeledContent("Start", value: "\(annotation.start)")
                    LabeledContent("End", value: "\(annotation.end)")
                    LabeledContent("Length", value: "\(annotation.totalLength) bp")
                    if annotation.isDiscontinuous {
                        LabeledContent("Intervals", value: "\(annotation.intervals.count)")
                    }
                }
                .font(.callout)
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
        case .contig: return "Contig"
        case .gap: return "Gap"
        case .scaffold: return "Scaffold"
        case .region: return "Region"
        case .source: return "Source"
        case .custom: return "Custom"
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
