// FASTQMetadataSection.swift - Inspector section for FASTQ sample metadata editing
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

// MARK: - FASTQMetadataSectionViewModel

/// View model for FASTQ sample metadata editing in the Inspector.
///
/// Manages loading, editing, and autosaving PHA4GE-aligned metadata for
/// individual `.lungfishfastq` bundles. Edits are autosaved with a debounce
/// interval after each keystroke.
@Observable
@MainActor
public final class FASTQMetadataSectionViewModel {

    /// The loaded metadata, if any.
    var metadata: FASTQSampleMetadata?

    /// The bundle URL currently displayed.
    var bundleURL: URL?

    /// Whether the section is expanded.
    var isExpanded: Bool = true

    /// Whether the template-specific details section is expanded.
    var showTemplateDetails: Bool = true

    /// Whether metadata is available (controls section visibility).
    var hasMetadata: Bool { metadata != nil }

    /// Filenames of attachments in the bundle.
    var attachmentFilenames: [String] = []

    /// Whether there are unsaved changes since last save.
    var hasUnsavedChanges: Bool { metadata != lastSavedMetadata }

    // MARK: - Internal State

    /// New custom field key being typed.
    var newCustomKey: String = ""

    /// New custom field value being typed.
    var newCustomValue: String = ""

    /// Snapshot of metadata at last save, for revert support.
    private var lastSavedMetadata: FASTQSampleMetadata?

    /// Debounce work item for autosave.
    private var autosaveWorkItem: DispatchWorkItem?

    /// Debounce interval for autosave (500ms).
    private let autosaveInterval: TimeInterval = 0.5

    /// Attachment manager for the current bundle.
    private var attachmentManager: BundleAttachmentManager?

    // MARK: - Callbacks

    /// Callback to persist metadata changes.
    var onSave: ((_ bundleURL: URL, _ metadata: FASTQSampleMetadata) -> Void)?

    // MARK: - Methods

    /// Loads metadata from a FASTQ bundle.
    func load(from bundleURL: URL) {
        self.bundleURL = bundleURL
        let sampleName = bundleURL.deletingPathExtension().lastPathComponent

        if let csvMeta = FASTQBundleCSVMetadata.load(from: bundleURL) {
            self.metadata = FASTQSampleMetadata(from: csvMeta, fallbackName: sampleName)
        } else {
            self.metadata = FASTQSampleMetadata(sampleName: sampleName)
        }

        lastSavedMetadata = metadata
        attachmentManager = BundleAttachmentManager(bundleURL: bundleURL)
        attachmentFilenames = attachmentManager?.listAttachments() ?? []
    }

    /// Clears the metadata display.
    func clear() {
        metadata = nil
        bundleURL = nil
        lastSavedMetadata = nil
        attachmentManager = nil
        attachmentFilenames = []
        autosaveWorkItem?.cancel()
    }

    /// Schedules an autosave after the debounce interval.
    func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.performSave()
                }
            }
        }
        autosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveInterval, execute: item)
    }

    /// Immediately saves current metadata to disk.
    func performSave() {
        guard let bundleURL, let metadata else { return }
        lastSavedMetadata = metadata
        let legacyCSV = metadata.toLegacyCSV()
        try? FASTQBundleCSVMetadata.save(legacyCSV, to: bundleURL)
        onSave?(bundleURL, metadata)
    }

    /// Reverts to the last saved state.
    func revertToLastSaved() {
        guard let lastSavedMetadata else { return }
        metadata = lastSavedMetadata
    }

    /// Clears all metadata fields except sample name, resetting to defaults.
    func clearAllMetadata() {
        guard let currentName = metadata?.sampleName else { return }
        metadata = FASTQSampleMetadata(sampleName: currentName)
        scheduleAutosave()
    }

    /// Applies metadata cloned from another sample (preserving the current sample name).
    func applyClonedMetadata(_ source: FASTQSampleMetadata) {
        guard let currentName = metadata?.sampleName else { return }
        metadata = source.cloned(withName: currentName)
        scheduleAutosave()
    }

    /// Sets the metadata template and triggers autosave.
    func setTemplate(_ template: MetadataTemplate) {
        metadata?.metadataTemplate = template
        scheduleAutosave()
    }

    /// Adds a new custom field.
    func addCustomField() {
        guard !newCustomKey.isEmpty else { return }
        metadata?.customFields[newCustomKey] = newCustomValue
        newCustomKey = ""
        newCustomValue = ""
        scheduleAutosave()
    }

    /// Removes a custom field.
    func removeCustomField(_ key: String) {
        metadata?.customFields.removeValue(forKey: key)
        scheduleAutosave()
    }

    /// Adds a file attachment to the bundle.
    func addAttachment(from sourceURL: URL) {
        guard let mgr = attachmentManager else { return }
        do {
            let filename = try mgr.addAttachment(from: sourceURL)
            metadata?.addAttachment(filename)
            attachmentFilenames = mgr.listAttachments()
            scheduleAutosave()
        } catch {
            // Attachment add failed
        }
    }

    /// Removes a file attachment from the bundle.
    func removeAttachment(_ filename: String) {
        guard let mgr = attachmentManager else { return }
        do {
            try mgr.removeAttachment(filename)
            metadata?.removeAttachment(filename)
            attachmentFilenames = mgr.listAttachments()
            scheduleAutosave()
        } catch {
            // Removal failed
        }
    }

    /// Opens an attachment in the default application.
    func openAttachment(_ filename: String) {
        guard let mgr = attachmentManager else { return }
        let url = mgr.urlForAttachment(filename)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Legacy API (for tests)

    var isEditing: Bool { true }
    var editingMetadata: FASTQSampleMetadata? {
        get { metadata }
        set { metadata = newValue }
    }
    func save() { performSave() }
    func beginEditing() {}
    func cancelEditing() { revertToLastSaved() }
}

// MARK: - FASTQMetadataSection View

/// SwiftUI section showing FASTQ sample metadata in the Inspector.
///
/// Layout is designed to be simple and template-driven:
/// 1. **Above the fold**: Sample Name, Template picker — always visible
/// 2. **Template fields**: Only fields relevant to the selected template
/// 3. **Notes & Attachments**: Collapsible at the bottom
public struct FASTQMetadataSection: View {
    @Bindable var viewModel: FASTQMetadataSectionViewModel

    public var body: some View {
        if viewModel.hasMetadata {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    keyFields
                    Divider()
                    templateFields
                    notesSection
                    attachmentsSection
                    customFieldsSection
                }
            } label: {
                HStack {
                    Text("Sample Metadata")
                        .font(.headline)
                    Spacer()
                    Menu {
                        Button("Revert to Last Saved") { viewModel.revertToLastSaved() }
                        Button("Clear All Metadata") { viewModel.clearAllMetadata() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .frame(width: 24)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Key Fields (Always Visible, Above the Fold)

    private var keyFields: some View {
        let template = viewModel.metadata?.metadataTemplate ?? .clinical

        return VStack(alignment: .leading, spacing: 6) {
            fieldRow("Sample Name", binding: Binding(
                get: { viewModel.metadata?.sampleName ?? "" },
                set: { viewModel.metadata?.sampleName = $0; viewModel.scheduleAutosave() }
            ))

            HStack {
                Text("Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                Picker("", selection: templateBinding) {
                    Text("Clinical").tag(MetadataTemplate.clinical)
                    Text("Wastewater").tag(MetadataTemplate.wastewater)
                    Text("Air Sample").tag(MetadataTemplate.airSample)
                    Text("Environmental").tag(MetadataTemplate.environmental)
                    Text("Custom").tag(MetadataTemplate.custom)
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if template == .airSample {
                fieldRow("Collection Start", binding: metaBinding(\.collectionDate))
                fieldRow("Collection End", binding: customBinding("collection_end_date"))
            } else {
                fieldRow("Collection Date", binding: metaBinding(\.collectionDate))
            }

            fieldRow("Geographic Location", binding: metaBinding(\.geoLocName))

            // Organism is not relevant for air/environmental samples
            if template == .clinical || template == .wastewater || template == .custom {
                fieldRow("Organism", binding: metaBinding(\.organism))
            }
        }
    }

    // MARK: - Template-Specific Fields

    @ViewBuilder
    private var templateFields: some View {
        let template = viewModel.metadata?.metadataTemplate ?? .clinical

        switch template {
        case .clinical:
            clinicalFields
        case .wastewater:
            wastewaterFields
        case .airSample:
            airSampleFields
        case .environmental:
            environmentalFields
        case .custom:
            EmptyView()
        }
    }

    private var clinicalFields: some View {
        DisclosureGroup("Clinical Details", isExpanded: $viewModel.showTemplateDetails) {
            VStack(alignment: .leading, spacing: 6) {
                fieldRow("Host", binding: metaBinding(\.host))
                fieldRow("Host Disease", binding: metaBinding(\.hostDisease))
                fieldRow("Sample Type", binding: metaBinding(\.sampleType))
                fieldRow("Specimen Source", binding: customBinding("specimen_source"))
                fieldRow("Anatomical Site", binding: customBinding("anatomical_site"))
                fieldRow("Patient Age", binding: customBinding("patient_age"))
                fieldRow("Patient Sex", binding: customBinding("patient_sex"))
                fieldRow("Symptom Onset", binding: customBinding("symptom_onset_date"))
                fieldRow("Hospitalization", binding: customBinding("hospitalization_status"))
                fieldRow("AMR", binding: customBinding("antimicrobial_resistance"))
                fieldRow("Patient ID", binding: metaBinding(\.patientId))
            }
        }
        .font(.caption)
    }

    private var wastewaterFields: some View {
        DisclosureGroup("Wastewater Details", isExpanded: $viewModel.showTemplateDetails) {
            VStack(alignment: .leading, spacing: 6) {
                fieldRow("Site Type", binding: customBinding("collection_site_type"))
                fieldRow("Population Served", binding: customBinding("population_served"))
                fieldRow("Flow Rate", binding: customBinding("flow_rate"))
                fieldRow("Composite/Grab", binding: customBinding("composite_vs_grab"))
                fieldRow("Treatment Stage", binding: customBinding("treatment_stage"))
                fieldRow("Catchment ID", binding: customBinding("catchment_area_id"))
            }
        }
        .font(.caption)
    }

    private var airSampleFields: some View {
        DisclosureGroup("Air Sampling Details", isExpanded: $viewModel.showTemplateDetails) {
            VStack(alignment: .leading, spacing: 6) {
                fieldRow("Method", binding: customBinding("sampling_method"))
                fieldRow("Flow Rate (LPM)", binding: customBinding("flow_rate_lpm"))
                fieldRow("Duration (min)", binding: customBinding("sampling_duration_minutes"))
                fieldRow("Indoor/Outdoor", binding: customBinding("indoor_outdoor"))
                fieldRow("Ventilation", binding: customBinding("ventilation_type"))
                fieldRow("Particle Size", binding: customBinding("particle_size_fraction"))
                fieldRow("Temperature (\u{00B0}C)", binding: customBinding("temperature_celsius"))
                fieldRow("Humidity (%)", binding: customBinding("relative_humidity_percent"))
                fieldRow("CO\u{2082} (ppm)", binding: customBinding("co2_ppm"))
                fieldRow("Occupancy", binding: customBinding("occupancy_count"))
            }
        }
        .font(.caption)
    }

    private var environmentalFields: some View {
        DisclosureGroup("Environmental Details", isExpanded: $viewModel.showTemplateDetails) {
            VStack(alignment: .leading, spacing: 6) {
                fieldRow("Biome", binding: customBinding("biome"))
                fieldRow("Medium", binding: customBinding("environmental_medium"))
                fieldRow("Depth (m)", binding: customBinding("depth_meters"))
                fieldRow("Elevation (m)", binding: customBinding("elevation_meters"))
                fieldRow("Feature", binding: customBinding("environmental_feature"))
                fieldRow("Isolation Source", binding: customBinding("isolation_source"))
            }
        }
        .font(.caption)
    }

    // MARK: - Notes

    @ViewBuilder
    private var notesSection: some View {
        Divider()
        DisclosureGroup("Notes") {
            TextEditor(text: Binding(
                get: { viewModel.metadata?.notes ?? "" },
                set: {
                    viewModel.metadata?.notes = $0.isEmpty ? nil : $0
                    viewModel.scheduleAutosave()
                }
            ))
            .font(.caption)
            .frame(minHeight: 50, maxHeight: 100)
            .border(Color.secondary.opacity(0.3))
        }
        .font(.caption)
    }

    // MARK: - Attachments

    @ViewBuilder
    private var attachmentsSection: some View {
        if !viewModel.attachmentFilenames.isEmpty || viewModel.bundleURL != nil {
            DisclosureGroup("Attachments (\(viewModel.attachmentFilenames.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.attachmentFilenames, id: \.self) { filename in
                        HStack {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            Text(filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button { viewModel.openAttachment(filename) } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .buttonStyle(.plain).controlSize(.small)
                            Button(role: .destructive) { viewModel.removeAttachment(filename) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain).controlSize(.small)
                        }
                    }
                    Button("Attach File\u{2026}") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = true
                        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()) { response in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    if response == .OK {
                                        for url in panel.urls {
                                            viewModel.addAttachment(from: url)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Custom Fields

    @ViewBuilder
    private var customFieldsSection: some View {
        let templateKeys = Set(viewModel.metadata?.metadataTemplate?.templateFields.map(\.key) ?? [])
        let customKeys = (viewModel.metadata?.customFields ?? [:]).keys
            .filter { !templateKeys.contains($0) }
            .sorted()

        if !customKeys.isEmpty || true {
            DisclosureGroup("Custom Fields") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(customKeys, id: \.self) { key in
                        HStack {
                            Text(key).font(.caption).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            TextField("", text: Binding(
                                get: { viewModel.metadata?.customFields[key] ?? "" },
                                set: { viewModel.metadata?.customFields[key] = $0; viewModel.scheduleAutosave() }
                            ))
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                            Button(role: .destructive) { viewModel.removeCustomField(key) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain).controlSize(.small)
                        }
                    }
                    HStack {
                        TextField("Key", text: $viewModel.newCustomKey)
                            .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 90)
                        TextField("Value", text: $viewModel.newCustomValue)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                        Button { viewModel.addCustomField() } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain).controlSize(.small)
                        .disabled(viewModel.newCustomKey.isEmpty)
                    }
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Binding Helpers

    private var templateBinding: Binding<MetadataTemplate> {
        Binding(
            get: { viewModel.metadata?.metadataTemplate ?? .clinical },
            set: { viewModel.setTemplate($0) }
        )
    }

    private func fieldRow(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    private func metaBinding(_ keyPath: WritableKeyPath<FASTQSampleMetadata, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.metadata?[keyPath: keyPath] ?? "" },
            set: {
                viewModel.metadata?[keyPath: keyPath] = $0.isEmpty ? nil : $0
                viewModel.scheduleAutosave()
            }
        )
    }

    private func customBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { viewModel.metadata?.customFields[key] ?? "" },
            set: {
                if $0.isEmpty {
                    viewModel.metadata?.customFields.removeValue(forKey: key)
                } else {
                    viewModel.metadata?.customFields[key] = $0
                }
                viewModel.scheduleAutosave()
            }
        )
    }
}
