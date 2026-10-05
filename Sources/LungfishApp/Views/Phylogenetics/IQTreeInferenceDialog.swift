// IQTreeInferenceDialog.swift - IQ-TREE operation sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit

/// The "Build Tree with IQ-TREE" sheet (rulings D1 to D7 and K4).
///
/// Every field is a titled control inside a grouped `Form`, so the visible
/// label and the accessible name are the same string. Rules that the user
/// needs to fill the form are visible captions, never hover-only help.
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
            primaryActionTitle: state.primaryActionTitle,
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

struct IQTreeInferenceToolPane: View {
    @Bindable var state: IQTreeInferenceDialogState

    var body: some View {
        Form {
            inputsSection
            modelSection
            branchSupportSection
            rootingSection
            outputSection
            runSection
            advancedSection
        }
        .formStyle(.grouped)
    }

    // MARK: Inputs

    private var inputsSection: some View {
        Section("Inputs") {
            LabeledContent("Alignment") {
                Text(state.inputSummary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityIdentifier("iqtree-options-alignment")

            if state.offersSelectedScope {
                Picker("Build from", selection: $state.scope) {
                    Text(state.wholeScopeTitle).tag(IQTreeBuildScope.whole)
                    Text(state.selectedScopeTitle).tag(IQTreeBuildScope.selected)
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Build from")
                .accessibilityIdentifier("iqtree-options-scope")
            } else {
                LabeledContent("Build from") {
                    Text(state.wholeScopeTitle)
                }
                .accessibilityIdentifier("iqtree-options-scope")
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            Picker("Model", selection: $state.modelChoice) {
                ForEach(state.modelChoices, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .accessibilityLabel("Model")
            .accessibilityIdentifier("iqtree-options-model")

            if state.modelChoice == .custom {
                labeledTextField("Custom model", text: $state.customModel, prompt: "GTR+F+I+G4", identifier: "iqtree-options-custom-model")
                caption("Enter any IQ-TREE model string. MF, TESTONLY and other ONLY presets build no tree.")
            }

            Picker("Sequence Type", selection: $state.sequenceType) {
                ForEach(state.availableSequenceTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .accessibilityLabel("Sequence Type")
            .accessibilityIdentifier("iqtree-options-sequence-type")

            if state.sequenceType == .codon {
                Picker("Genetic code", selection: $state.geneticCode) {
                    ForEach(IQTreeGeneticCode.allCases, id: \.self) { code in
                        Text(code.displayName).tag(code)
                    }
                }
                .accessibilityLabel("Genetic code")
                .accessibilityIdentifier("iqtree-options-genetic-code")
            }
        }
    }

    // MARK: Branch support

    private var branchSupportSection: some View {
        Section {
            Toggle("Ultrafast bootstrap (UFBoot)", isOn: $state.bootstrapEnabled)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Ultrafast bootstrap (UFBoot)")
                .accessibilityIdentifier("iqtree-options-bootstrap-checkbox")
            replicateField(
                "UFBoot replicates",
                text: $state.bootstrapReplicatesText,
                stepperValue: $state.bootstrapReplicatesStepperValue,
                range: IQTreeInferenceDialogState.ufbootRange,
                step: IQTreeInferenceDialogState.ufbootStep,
                isEnabled: state.isBranchSupportAvailable && state.bootstrapEnabled,
                identifier: "iqtree-options-bootstrap-count"
            )
            caption(IQTreeInferenceDialogState.ufbootMinimumCaption)

            Toggle("SH-aLRT test", isOn: $state.alrtEnabled)
                .toggleStyle(.checkbox)
                .accessibilityLabel("SH-aLRT test")
                .accessibilityIdentifier("iqtree-options-alrt-checkbox")
            replicateField(
                "SH-aLRT replicates",
                text: $state.alrtReplicatesText,
                stepperValue: $state.alrtReplicatesStepperValue,
                range: IQTreeInferenceDialogState.alrtRange,
                step: IQTreeInferenceDialogState.alrtStep,
                isEnabled: state.isBranchSupportAvailable && state.alrtEnabled,
                identifier: "iqtree-options-alrt-count"
            )

            caption(IQTreeInferenceDialogState.branchSupportCaption)
            if let unavailable = state.branchSupportUnavailableCaption {
                caption(unavailable)
                    .accessibilityIdentifier("iqtree-options-branch-support-unavailable")
            }
        } header: {
            Text("Branch Support")
        }
        .disabled(state.isBranchSupportAvailable == false)
    }

    // MARK: Rooting

    private var rootingSection: some View {
        Section("Rooting") {
            LabeledContent("Outgroup") {
                if state.outgroupCandidates.isEmpty {
                    Text("No sequence names can be used")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(state.outgroupCandidates, id: \.self) { name in
                                Toggle(name, isOn: outgroupBinding(for: name))
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            .accessibilityIdentifier("iqtree-options-outgroup")
            caption(IQTreeInferenceDialogState.outgroupCaption)
            if state.hasCommaNamesExcludedFromOutgroup {
                caption(IQTreeInferenceDialogState.outgroupCommaCaption)
            }
        }
    }

    private func outgroupBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { state.isOutgroupSelected(name) },
            set: { state.setOutgroup(name, selected: $0) }
        )
    }

    // MARK: Output and Run

    private var outputSection: some View {
        Section("Output") {
            labeledTextField("Name", text: $state.outputName, identifier: "iqtree-options-output-name")
        }
    }

    private var runSection: some View {
        Section("Run") {
            labeledTextField(
                "Seed",
                text: $state.seedText,
                prompt: IQTreeInferenceDialogState.seedPlaceholder,
                identifier: "iqtree-options-seed"
            )
            caption(IQTreeInferenceDialogState.seedCaption)
            labeledTextField("Threads", text: $state.threadsText, identifier: "iqtree-options-threads")
            caption(IQTreeInferenceDialogState.threadsCaption)
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $state.advancedOptionsExpanded) {
                Toggle("Safe numerical mode", isOn: $state.safeMode)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Safe numerical mode")
                    .accessibilityIdentifier("iqtree-options-safe-mode")
                caption(IQTreeInferenceDialogState.safeModeCaption)
                Toggle("Keep identical sequences", isOn: $state.keepIdenticalSequences)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Keep identical sequences")
                    .accessibilityIdentifier("iqtree-options-keep-identical")
                caption(IQTreeInferenceDialogState.keepIdenticalCaption)
                labeledTextField(
                    "IQ-TREE executable",
                    text: $state.iqtreePath,
                    prompt: "Bundled iqtree3",
                    identifier: "iqtree-options-executable-path"
                )
                labeledTextField(
                    "Additional IQ-TREE parameters",
                    text: $state.extraIQTreeOptions,
                    identifier: "iqtree-options-advanced-parameters"
                )
                caption(IQTreeInferenceDialogState.advancedParametersCaption)
            } label: {
                Text("Advanced")
                    .accessibilityIdentifier("iqtree-options-advanced-disclosure")
            }
        }
    }

    // MARK: Helpers

    private func replicateField(
        _ title: String,
        text: Binding<String>,
        stepperValue: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        isEnabled: Bool,
        identifier: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                    .accessibilityIdentifier(identifier)
                Stepper(title, value: stepperValue, in: range, step: step)
                    .labelsHidden()
            }
        }
        .disabled(isEnabled == false)
    }

    /// A titled text field whose accessible name is its visible label. In a
    /// grouped Form a bare `TextField(title, text:)` draws the title as a
    /// separate static text and leaves the field unnamed in the AX tree.
    private func labeledTextField(
        _ title: String,
        text: Binding<String>,
        prompt: String? = nil,
        identifier: String
    ) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .accessibilityIdentifier(identifier)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
