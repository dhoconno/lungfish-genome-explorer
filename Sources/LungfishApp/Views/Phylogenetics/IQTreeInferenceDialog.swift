// IQTreeInferenceDialog.swift - IQ-TREE operation sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SwiftUI
import LungfishWorkflow

enum IQTreeSequenceTypeOption: String, CaseIterable, Sendable {
    case auto = "Auto"
    case dna = "DNA"
    case aminoAcid = "AA"
    case codon = "CODON"
    case binary = "BIN"
    case morphological = "MORPH"
    case nucleotideToAminoAcid = "NT2AA"

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .dna:
            return "DNA"
        case .aminoAcid:
            return "Amino Acid"
        case .codon:
            return "Codon"
        case .binary:
            return "Binary"
        case .morphological:
            return "Morphological"
        case .nucleotideToAminoAcid:
            return "NT to AA"
        }
    }
}

@MainActor
@Observable
final class IQTreeInferenceDialogState {
    static let toolID = "iqtree"

    let request: MultipleSequenceAlignmentTreeInferenceRequest
    let projectURL: URL
    let sidebarItems: [DatasetOperationToolSidebarItem]

    var selectedToolID: String
    var outputName: String
    var model: String
    var sequenceType: IQTreeSequenceTypeOption
    var bootstrapEnabled: Bool
    var bootstrapReplicates: Int
    var alrtEnabled: Bool
    var alrtReplicates: Int
    var seed: Int?
    var threads: Int?
    var safeMode: Bool
    var keepIdenticalSequences: Bool
    var advancedOptionsExpanded: Bool
    var iqtreePath: String
    var extraIQTreeOptions: String
    var pendingOptions: IQTreeInferenceOptions?

    init(
        request: MultipleSequenceAlignmentTreeInferenceRequest,
        projectURL: URL,
        sidebarItems: [DatasetOperationToolSidebarItem] = [
            DatasetOperationToolSidebarItem(
                id: IQTreeInferenceDialogState.toolID,
                title: "Build Tree with IQ-TREE",
                subtitle: "Infer a maximum-likelihood phylogenetic tree from an alignment.",
                availability: .available
            )
        ]
    ) {
        self.request = request
        self.projectURL = projectURL
        self.sidebarItems = sidebarItems
        self.selectedToolID = Self.toolID
        self.outputName = Self.normalizedOutputName(request.suggestedName)
        self.model = "MFP"
        self.sequenceType = .auto
        self.bootstrapEnabled = false
        self.bootstrapReplicates = 1000
        self.alrtEnabled = false
        self.alrtReplicates = 1000
        self.seed = 1
        self.threads = nil
        self.safeMode = false
        self.keepIdenticalSequences = false
        self.advancedOptionsExpanded = false
        self.iqtreePath = ""
        self.extraIQTreeOptions = ""
        self.pendingOptions = nil
    }

    var dialogTitle: String {
        "Phylogenetic Tree Operations"
    }

    var dialogSubtitle: String {
        "Configure IQ-TREE for the selected multiple sequence alignment."
    }

    var datasetLabel: String {
        request.displayName
    }

    var selectedToolSummary: String {
        "Build a native .lungfishtree bundle with IQ-TREE through lungfish-cli. The output records resolved options, runtime identity, inputs, outputs, and command provenance."
    }

    var scopeSummary: String {
        var parts: [String] = []
        if let rows = request.rows?.trimmingCharacters(in: .whitespacesAndNewlines), rows.isEmpty == false {
            let rowCount = rows.split(separator: ",").count
            parts.append("\(rowCount) \(rowCount == 1 ? "row" : "rows")")
        }
        if let columns = request.columns?.trimmingCharacters(in: .whitespacesAndNewlines), columns.isEmpty == false {
            parts.append("columns \(columns)")
        }
        return parts.isEmpty ? "Full alignment" : "Selected " + parts.joined(separator: ", ")
    }

    var inputSummary: String {
        FASTQOperationDialogState.displayPath(for: request.bundleURL, relativeTo: projectURL)
    }

    var readinessText: String {
        validationMessage ?? "Ready to build a phylogenetic tree."
    }

    var isRunEnabled: Bool {
        validationMessage == nil
    }

    var validationMessage: String? {
        if outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an output name."
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter an IQ-TREE model or model selection preset."
        }
        if bootstrapEnabled && bootstrapReplicates <= 0 {
            return "Enter a positive ultrafast bootstrap replicate count."
        }
        if alrtEnabled && alrtReplicates <= 0 {
            return "Enter a positive SH-aLRT replicate count."
        }
        if let seed, seed <= 0 {
            return "Enter a positive seed or leave it blank."
        }
        if let threads, threads <= 0 {
            return "Enter a positive thread count or leave it blank."
        }
        do {
            _ = try AdvancedCommandLineOptions.parse(extraIQTreeOptions)
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    func selectTool(named rawValue: String) {
        guard rawValue == Self.toolID else { return }
        selectedToolID = rawValue
    }

    func prepareForRun() {
        guard isRunEnabled else {
            pendingOptions = nil
            return
        }
        pendingOptions = IQTreeInferenceOptions(
            outputName: Self.normalizedOutputName(outputName),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            sequenceType: sequenceType.rawValue,
            bootstrap: bootstrapEnabled ? bootstrapReplicates : nil,
            alrt: alrtEnabled ? alrtReplicates : nil,
            seed: seed,
            threads: threads,
            safeMode: safeMode,
            keepIdenticalSequences: keepIdenticalSequences,
            iqtreePath: trimmedOptional(iqtreePath),
            extraIQTreeOptions: extraIQTreeOptions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func trimmedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "iqtree-analysis" : trimmed
        return name.hasSuffix(".lungfishtree")
            ? String(name.dropLast(".lungfishtree".count))
            : name
    }
}

struct IQTreeInferenceDialog: View {
    @Bindable var state: IQTreeInferenceDialogState
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: state.dialogTitle,
            subtitle: state.dialogSubtitle,
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: state.readinessText,
            isRunEnabled: state.isRunEnabled,
            accessibilityNamespace: "iqtree-options",
            onSelectTool: state.selectTool(named:),
            onCancel: onCancel,
            onRun: handleRun
        ) {
            IQTreeInferenceToolPane(state: state)
        }
    }

    private func handleRun() {
        state.prepareForRun()
        guard state.pendingOptions != nil else { return }
        onRun()
    }
}

private struct IQTreeInferenceToolPane: View {
    @Bindable var state: IQTreeInferenceDialogState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(DatasetOperationSection.overview.title) {
                    Text(state.selectedToolSummary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                section(DatasetOperationSection.inputs.title) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(state.inputSummary, systemImage: "rectangle.stack")
                            .font(.body)
                        labeledValue("Scope", value: state.scopeSummary)
                            .accessibilityIdentifier("iqtree-options-scope")
                    }
                }

                section(DatasetOperationSection.primarySettings.title) {
                    VStack(alignment: .leading, spacing: 12) {
                        labeledTextField("Output Name", text: $state.outputName)
                            .accessibilityIdentifier("iqtree-options-output-name")
                        labeledTextField("Model", text: $state.model)
                            .accessibilityIdentifier("iqtree-options-model")

                        Picker("Sequence Type", selection: $state.sequenceType) {
                            ForEach(IQTreeSequenceTypeOption.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("iqtree-options-sequence-type")

                        branchSupportControls

                        HStack(spacing: 12) {
                            labeledCompactTextField("Seed", text: Self.optionalIntBinding(state, \.seed))
                                .accessibilityIdentifier("iqtree-options-seed")
                            labeledCompactTextField("Threads", text: Self.optionalIntBinding(state, \.threads))
                                .accessibilityIdentifier("iqtree-options-threads")
                        }

                        Toggle("Safe numerical mode", isOn: $state.safeMode)
                            .accessibilityIdentifier("iqtree-options-safe-mode")
                        Toggle("Keep identical sequences", isOn: $state.keepIdenticalSequences)
                            .accessibilityIdentifier("iqtree-options-keep-identical")
                    }
                }

                section(DatasetOperationSection.advancedSettings.title) {
                    DisclosureGroup("Advanced Options", isExpanded: $state.advancedOptionsExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledTextField("IQ-TREE Executable", text: $state.iqtreePath)
                                .accessibilityIdentifier("iqtree-options-executable-path")
                            labeledTextField("IQ-TREE Parameters", text: $state.extraIQTreeOptions)
                                .accessibilityIdentifier("iqtree-options-advanced-parameters")
                            Text("Advanced parameters are passed directly to IQ-TREE after the curated options.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .accessibilityIdentifier("iqtree-options-advanced-disclosure")
                }

                section(DatasetOperationSection.readiness.title) {
                    Text(state.readinessText)
                        .font(.callout)
                        .foregroundStyle(state.isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private var branchSupportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Branch Support")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 12) {
                Toggle("Ultrafast Bootstrap", isOn: $state.bootstrapEnabled)
                    .accessibilityIdentifier("iqtree-options-bootstrap-checkbox")
                labeledCompactTextField("Replicates", text: Self.intBinding(state, \.bootstrapReplicates))
                    .accessibilityIdentifier("iqtree-options-bootstrap-count")
            }
            HStack(spacing: 12) {
                Toggle("SH-aLRT", isOn: $state.alrtEnabled)
                    .accessibilityIdentifier("iqtree-options-alrt-checkbox")
                labeledCompactTextField("Replicates", text: Self.intBinding(state, \.alrtReplicates))
                    .accessibilityIdentifier("iqtree-options-alrt-count")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledValue(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 180, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func labeledTextField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 180, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
        }
    }

    private func labeledCompactTextField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .frame(width: 86, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
        }
    }

    private static func intBinding(
        _ state: IQTreeInferenceDialogState,
        _ keyPath: WritableKeyPath<IQTreeInferenceDialogState, Int>
    ) -> Binding<String> {
        Binding(
            get: { String(state[keyPath: keyPath]) },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Int(trimmed) {
                    var mutableState = state
                    mutableState[keyPath: keyPath] = value
                }
            }
        )
    }

    private static func optionalIntBinding(
        _ state: IQTreeInferenceDialogState,
        _ keyPath: WritableKeyPath<IQTreeInferenceDialogState, Int?>
    ) -> Binding<String> {
        Binding(
            get: { state[keyPath: keyPath].map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var mutableState = state
                mutableState[keyPath: keyPath] = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }
}
