// SampleQueryBuilderSheet.swift - SwiftUI query builder for sample filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

private enum SampleQueryField: String, CaseIterable, Identifiable {
    case text
    case name
    case source
    case visible
    case metadata

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Any Text"
        case .name: return "Sample Name"
        case .source: return "Source"
        case .visible: return "Visibility"
        case .metadata: return "Metadata"
        }
    }
}

private struct SampleQueryRuleUI: Identifiable {
    let id = UUID()
    var field: SampleQueryField = .name
    var metadataField: String = ""
    var op: String = "="
    var value: String = ""

    func toClause() -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .text:
            guard !trimmed.isEmpty else { return nil }
            return "text=\(trimmed)"
        case .name:
            guard !trimmed.isEmpty else { return nil }
            return "name\(op)\(trimmed)"
        case .source:
            guard !trimmed.isEmpty else { return nil }
            return "source\(op)\(trimmed)"
        case .visible:
            if value == "visible" { return "visible=true" }
            if value == "hidden" { return "visible=false" }
            return nil
        case .metadata:
            let key = metadataField.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !trimmed.isEmpty else { return nil }
            return "meta.\(key)\(op)\(trimmed)"
        }
    }
}

struct SampleQueryBuilderView: View {
    @State private var rules: [SampleQueryRuleUI] = [SampleQueryRuleUI()]
    let initialFilterText: String
    let metadataFields: [String]
    let onApply: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sample Query Builder")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($rules) { $rule in
                        HStack(spacing: 6) {
                            Picker("", selection: $rule.field) {
                                ForEach(SampleQueryField.allCases) { field in
                                    Text(field.label).tag(field)
                                }
                            }
                            .frame(width: 130)

                            if rule.field == .metadata {
                                Picker("", selection: $rule.metadataField) {
                                    Text("Metadata Field").tag("")
                                    ForEach(metadataFields, id: \.self) { field in
                                        Text(field).tag(field)
                                    }
                                }
                                .frame(width: 150)
                            }

                            if rule.field != .visible {
                                Picker("", selection: $rule.op) {
                                    Text("contains").tag("=")
                                    Text("not contains").tag("!=")
                                }
                                .frame(width: 110)

                                TextField("Value", text: $rule.value)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 180)
                            } else {
                                Picker("", selection: $rule.value) {
                                    Text("Visible").tag("visible")
                                    Text("Hidden").tag("hidden")
                                }
                                .frame(width: 140)
                            }

                            Button {
                                removeRule(rule.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(minHeight: 140, maxHeight: 340)

            HStack {
                Button {
                    var next = SampleQueryRuleUI()
                    next.field = metadataFields.isEmpty ? .name : .metadata
                    if let first = metadataFields.first {
                        next.metadataField = first
                    }
                    if next.field == .visible {
                        next.value = "visible"
                    }
                    rules.append(next)
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
                Spacer()
                if !initialFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Current: \(initialFilterText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            HStack {
                Button("Clear All") {
                    rules = [SampleQueryRuleUI()]
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    let clauses = rules.compactMap { $0.toClause() }
                    onApply(clauses.joined(separator: "; "))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 700, height: min(CGFloat(rules.count) * 56 + 220, 560))
        .onAppear {
            // Seed metadata rule defaults after first render.
            if let first = metadataFields.first {
                for idx in rules.indices where rules[idx].field == .metadata && rules[idx].metadataField.isEmpty {
                    rules[idx].metadataField = first
                }
            }
        }
    }

    private func removeRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        if rules.isEmpty {
            rules = [SampleQueryRuleUI()]
        }
    }
}
