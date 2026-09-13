import Observation
import SwiftUI

@Observable @MainActor
final class PrimerOrderExportViewModel {
    let draft: PrimerOrderDraft
    var metadata: PrimerOrderMetadata
    var metadataExpanded = false

    init(draft: PrimerOrderDraft) {
        self.draft = draft
        self.metadata = PrimerOrderMetadata(name: draft.defaultName)
    }

    var validationMessage: String? {
        if draft.oligos.isEmpty { return "No oligos are included in this order." }
        if metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name for this order."
        }
        return nil
    }
}

/// Reviews the immutable displayed set captured when the Inspector action was invoked.
struct PrimerOrderExportView: View {
    @Bindable var model: PrimerOrderExportViewModel
    var onCancel: () -> Void
    var onExport: (PrimerOrderDraft, PrimerOrderMetadata) -> Void

    private var poolNames: [String] {
        var seen: Set<String> = []
        return model.draft.oligos.compactMap { seen.insert($0.poolName).inserted ? $0.poolName : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                Text("Export Displayed Primer Order").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    frozenSelectionSummary
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Order name").font(.callout.weight(.medium))
                        TextField("Order name", text: $model.metadata.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("primerOrderExport.name")
                        if let message = model.validationMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Saved in this project’s Analyses folder. Includes a workbook with the IDT template and Order metadata, an upload-only workbook, and a detailed CSV. The JSON record preserves the selected oligos and filter settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    orderMetadata
                    Divider()
                    oligoPreview
                }
                .padding(20)
            }
            .frame(maxHeight: 620)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard model.validationMessage == nil else { return }
                    onExport(model.draft, model.metadata)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.validationMessage != nil)
                .accessibilityIdentifier("primerOrderExport.export")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("primerOrderExport.sheet")
    }

    private var frozenSelectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.draft.oligos.count) oligos · \(poolNames.count) pools · \(Set(model.draft.oligos.map(\.sourceResultID)).count) schemes")
                .font(.headline).monospacedDigit()
                .accessibilityIdentifier("primerOrderExport.count")
            Text(model.draft.sourceName).font(.callout).textSelection(.enabled)
            Text("This is the displayed set captured when this sheet opened, across all schemes and references. Display changes made later do not change this order.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(poolNames, id: \.self) { poolName in
                HStack(alignment: .firstTextBaseline) {
                    Text(poolName).lineLimit(2).help(poolName)
                    Spacer(minLength: 12)
                    Text("\(model.draft.oligos.filter { $0.poolName == poolName }.count) oligos")
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var orderMetadata: some View {
        DisclosureGroup("Order details (optional)", isExpanded: $model.metadataExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                metadataField("Requested by", text: $model.metadata.requestedBy, id: "requestedBy")
                metadataField("Project label", text: $model.metadata.project, id: "project")
                metadataField("Order reference", text: $model.metadata.orderReference, id: "orderReference")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextField("Optional order notes", text: $model.metadata.notes, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("primerOrderExport.notes")
                }
                Text("These details are included on the Order metadata worksheet and in the CSV and JSON records.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
        }
        .accessibilityIdentifier("primerOrderExport.metadata")
    }

    private func metadataField(_ label: String, text: Binding<String>, id: String) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
            TextField("Optional", text: text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .accessibilityIdentifier("primerOrderExport.\(id)")
        }.font(.callout)
    }

    private var oligoPreview: some View {
        let preview = Array(model.draft.oligos.prefix(8))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Oligo preview").font(.callout.weight(.medium))
                Spacer()
                Text("\(preview.count) of \(model.draft.oligos.count) shown")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(preview) { oligo in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(oligo.name).fontWeight(.medium).lineLimit(1).help(oligo.name)
                        Spacer(minLength: 12)
                        Text(oligo.poolName).foregroundStyle(.secondary).lineLimit(1).help(oligo.poolName)
                    }.font(.caption)
                    Text(oligo.sequence).font(.system(.caption, design: .monospaced))
                        .lineLimit(1).help(oligo.sequence).textSelection(.enabled)
                }
            }
            Text("Stored sequences are shown 5′–3′. Every captured oligo is exported, including entries beyond this preview.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Owns the sheet's editable form for the lifetime of one captured draft.
struct PrimerOrderExportSheet: View {
    @State private var model: PrimerOrderExportViewModel
    var onCancel: () -> Void
    var onExport: (PrimerOrderDraft, PrimerOrderMetadata) -> Void

    init(draft: PrimerOrderDraft, onCancel: @escaping () -> Void,
         onExport: @escaping (PrimerOrderDraft, PrimerOrderMetadata) -> Void) {
        _model = State(initialValue: PrimerOrderExportViewModel(draft: draft))
        self.onCancel = onCancel
        self.onExport = onExport
    }

    var body: some View {
        PrimerOrderExportView(model: model, onCancel: onCancel, onExport: onExport)
    }
}
