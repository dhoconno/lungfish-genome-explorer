import LungfishWorkflow
import Observation
import SwiftUI

@Observable @MainActor
final class PrimerSchemeExportViewModel {
    let candidates: [PrimerSchemeFromAnalysisCandidate]
    let analysisName: String
    var selectedResultID: UUID?
    var name: String

    init(candidates: [PrimerSchemeFromAnalysisCandidate], analysisName: String) {
        self.candidates = candidates
        self.analysisName = analysisName
        let first = candidates.first(where: \.isExportable)
        selectedResultID = first?.resultID
        name = Self.defaultName(analysisName: analysisName, candidate: first)
    }

    var selected: PrimerSchemeFromAnalysisCandidate? {
        candidates.first { $0.resultID == selectedResultID }
    }

    func select(_ id: UUID?) {
        let previousDefault = Self.defaultName(analysisName: analysisName, candidate: selected)
        selectedResultID = id
        if name == previousDefault { name = Self.defaultName(analysisName: analysisName, candidate: selected) }
    }

    var validationMessage: String? {
        guard let selected else { return "Choose a result to save." }
        if let reason = selected.refusalReason { return reason }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name for the primer scheme." }
        if trimmed.hasPrefix(".") || trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\\") {
            return "Enter a name without path separators."
        }
        return nil
    }

    static func defaultName(analysisName: String, candidate: PrimerSchemeFromAnalysisCandidate?) -> String {
        guard let candidate else { return analysisName }
        return "\(analysisName) \(candidate.label) scheme"
    }
}

/// Names the scheme and states which sequence its coordinates belong to before anything is written.
struct PrimerSchemeExportView: View {
    @Bindable var model: PrimerSchemeExportViewModel
    var onCancel: () -> Void
    var onSave: (PrimerSchemeFromAnalysisCandidate, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").foregroundStyle(.secondary)
                Text("Save as Primer Scheme").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.analysisName).font(.callout).textSelection(.enabled)
                    if model.candidates.count > 1 {
                        Picker("Result", selection: Binding(get: { model.selectedResultID }, set: { model.select($0) })) {
                            ForEach(model.candidates) { candidate in
                                Text(candidate.isExportable ? candidate.label : "\(candidate.label) (cannot be saved)")
                                    .tag(Optional(candidate.resultID))
                            }
                        }
                        .accessibilityIdentifier("primerSchemeExport.result")
                    }
                    if let candidate = model.selected {
                        candidateSummary(candidate)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scheme name").font(.callout.weight(.medium))
                        TextField("Scheme name", text: $model.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("primerSchemeExport.name")
                        if let message = model.validationMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("primerSchemeExport.validation")
                        }
                    }
                    Text("Saved in this project’s Primer Schemes folder as a .lungfishprimers bundle. The Primer Trim dialog and the Viral Recon wizard list it under In This Project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .frame(maxHeight: 560)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard model.validationMessage == nil, let candidate = model.selected else { return }
                    onSave(candidate, model.name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.validationMessage != nil)
                .accessibilityIdentifier("primerSchemeExport.save")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("primerSchemeExport.sheet")
    }

    @ViewBuilder
    private func candidateSummary(_ candidate: PrimerSchemeFromAnalysisCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = candidate.refusalReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("primerSchemeExport.refusal")
            } else {
                Text("\(candidate.engine) · \(candidate.primerCount) primers · \(candidate.ampliconCount) amplicons · \(candidate.poolCount) pools")
                    .font(.headline).monospacedDigit()
                    .accessibilityIdentifier("primerSchemeExport.summary")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coordinate reference").font(.callout.weight(.medium))
                    Text(candidate.referenceID).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(candidate.referenceStatement).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("primerSchemeExport.referenceStatement")
                }
                ForEach(candidate.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PrimerSchemeExportSheet: View {
    @State private var model: PrimerSchemeExportViewModel
    var onCancel: () -> Void
    var onSave: (PrimerSchemeFromAnalysisCandidate, String) -> Void

    init(candidates: [PrimerSchemeFromAnalysisCandidate], analysisName: String,
         onCancel: @escaping () -> Void, onSave: @escaping (PrimerSchemeFromAnalysisCandidate, String) -> Void) {
        _model = State(initialValue: PrimerSchemeExportViewModel(candidates: candidates, analysisName: analysisName))
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        PrimerSchemeExportView(model: model, onCancel: onCancel, onSave: onSave)
    }
}
