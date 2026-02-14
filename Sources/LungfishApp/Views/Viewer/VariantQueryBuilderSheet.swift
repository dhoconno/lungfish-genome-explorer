// VariantQueryBuilderSheet.swift - SwiftUI query builder for variant filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import os.log

private let queryLogger = Logger(subsystem: "com.lungfish.app", category: "QueryBuilder")

// MARK: - Query Builder View

/// SwiftUI view for the variant query builder sheet.
///
/// Allows users to build complex variant queries by adding rules with
/// category/field/operator/value selection, and choosing presets.
struct VariantQueryBuilderView: View {
    @State private var rules: [QueryRule]
    @State private var logic: QueryLogic = .matchAll
    @State private var selectedPresetId: UUID?
    @State private var showSaveDialog = false
    @State private var savePresetName = ""

    let availableInfoKeys: Set<String>
    let availableVariantTypes: [String]
    let sampleNames: [String]
    let savedPresets: [QueryPreset]
    let onApply: (String) -> Void
    let onSavePreset: (QueryPreset) -> Void
    let onCancel: () -> Void

    init(
        initialFilterText: String = "",
        availableInfoKeys: Set<String> = [],
        availableVariantTypes: [String] = [],
        sampleNames: [String] = [],
        savedPresets: [QueryPreset] = [],
        onApply: @escaping (String) -> Void,
        onSavePreset: @escaping (QueryPreset) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.availableInfoKeys = availableInfoKeys
        self.availableVariantTypes = availableVariantTypes
        self.sampleNames = sampleNames
        self.savedPresets = savedPresets
        self.onApply = onApply
        self.onSavePreset = onSavePreset
        self.onCancel = onCancel
        _rules = State(initialValue: [QueryRule()])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("Variant Query Builder")
                    .font(.headline)
                Spacer()
                // Logic selector
                Picker("", selection: $logic) {
                    ForEach(QueryLogic.allCases, id: \.self) { logic in
                        Text(logic.displayName).tag(logic)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Preset bar
            HStack(spacing: 8) {
                Text("Presets:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(allPresets) { preset in
                    Button(preset.name) {
                        loadPreset(preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedPresetId == preset.id ? Color.accentColor : nil)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            // Rules list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach($rules) { $rule in
                        RuleRowView(
                            rule: $rule,
                            availableInfoKeys: availableInfoKeys,
                            availableVariantTypes: availableVariantTypes,
                            onRemove: { removeRule(rule.id) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(minHeight: 100, maxHeight: 300)

            // Add rule button
            HStack {
                Button {
                    rules.append(QueryRule())
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // Action buttons
            HStack {
                Button("Save Preset...") {
                    savePresetName = ""
                    showSaveDialog = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applyQuery()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 640, height: min(CGFloat(rules.count) * 44 + 240, 520))
        .sheet(isPresented: $showSaveDialog) {
            SavePresetDialogView(
                name: $savePresetName,
                onSave: {
                    let preset = QueryPreset(
                        name: savePresetName,
                        rules: rules,
                        logic: logic
                    )
                    onSavePreset(preset)
                    showSaveDialog = false
                },
                onCancel: { showSaveDialog = false }
            )
        }
    }

    private var allPresets: [QueryPreset] {
        let relevant = QueryPreset.builtInPresets.filter { preset in
            preset.rules.allSatisfy { rule in
                rule.category == .callQuality || rule.category == .location || rule.category == .identity
                || availableInfoKeys.contains(rule.field)
            }
        }
        return relevant + savedPresets
    }

    private func loadPreset(_ preset: QueryPreset) {
        rules = preset.rules
        logic = preset.logic
        selectedPresetId = preset.id
    }

    private func removeRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        if rules.isEmpty {
            rules.append(QueryRule())
        }
    }

    private func applyQuery() {
        let clauses = rules.compactMap { $0.toFilterClause() }
        guard !clauses.isEmpty else {
            onApply("")
            return
        }
        let filterText = clauses.joined(separator: "; ")
        queryLogger.info("Query builder applied: \(filterText)")
        onApply(filterText)
    }
}

// MARK: - Rule Row View

private struct RuleRowView: View {
    @Binding var rule: QueryRule
    let availableInfoKeys: Set<String>
    let availableVariantTypes: [String]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Category picker
            Picker("", selection: $rule.category) {
                ForEach(QueryCategory.allCases) { cat in
                    Text(cat.displayName).tag(cat)
                }
            }
            .frame(width: 140)
            .onChange(of: rule.category) { _, newCat in
                let fields = effectiveFields(for: newCat)
                if !fields.contains(rule.field), let first = fields.first {
                    rule.field = first
                }
                let ops = newCat.operators(for: rule.field)
                if !ops.contains(rule.op), let first = ops.first {
                    rule.op = first
                }
            }

            // Field picker
            Picker("", selection: $rule.field) {
                ForEach(effectiveFields(for: rule.category), id: \.self) { field in
                    Text(field).tag(field)
                }
            }
            .frame(width: 120)
            .onChange(of: rule.field) { _, newField in
                let ops = rule.category.operators(for: newField)
                if !ops.contains(rule.op), let first = ops.first {
                    rule.op = first
                }
            }

            // Operator picker
            Picker("", selection: $rule.op) {
                ForEach(rule.category.operators(for: rule.field), id: \.self) { op in
                    Text(op).tag(op)
                }
            }
            .frame(width: 60)

            // Value field
            valueInput

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            if rule.field.isEmpty, let first = effectiveFields(for: rule.category).first {
                rule.field = first
            }
        }
    }

    @ViewBuilder
    private var valueInput: some View {
        if rule.category == .identity && rule.field == "Type" {
            Picker("", selection: $rule.value) {
                Text("Any").tag("")
                ForEach(availableVariantTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .frame(minWidth: 80)
        } else if rule.category == .biologicalEffect && rule.field == "IMPACT" {
            Picker("", selection: $rule.value) {
                Text("Any").tag("")
                Text("HIGH").tag("HIGH")
                Text("MODERATE").tag("MODERATE")
                Text("LOW").tag("LOW")
                Text("MODIFIER").tag("MODIFIER")
            }
            .frame(minWidth: 100)
        } else if rule.category == .callQuality && rule.field == "Filter" {
            Picker("", selection: $rule.value) {
                Text("Any").tag("")
                Text("PASS").tag("PASS")
            }
            .frame(minWidth: 80)
        } else {
            TextField("Value", text: $rule.value)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 80)
        }
    }

    /// Fields for the category, enriched with available INFO keys.
    private func effectiveFields(for category: QueryCategory) -> [String] {
        var fields = category.fields
        if category == .biologicalEffect || category == .population {
            // Add available INFO keys that aren't already in the default list
            let existing = Set(fields)
            for key in availableInfoKeys.sorted() where !existing.contains(key) {
                let isPopulation = key.contains("AF") || key.contains("freq")
                let isBio = key.contains("IMPACT") || key.contains("GENE") || key.contains("CLIN")
                    || key.contains("SIG") || key.contains("ANN") || key.contains("CSQ")
                if (category == .population && isPopulation) || (category == .biologicalEffect && isBio) {
                    fields.append(key)
                }
            }
        }
        return fields
    }
}

// MARK: - Save Preset Dialog

private struct SavePresetDialogView: View {
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Save Query Preset")
                .font(.headline)
            TextField("Preset Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
