// PrimerSchemePickerView.swift - List-style picker for primer scheme bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

/// A list-style picker for primer scheme bundles, showing built-in and
/// project-local sections with row-level selection and a Browse button.
struct PrimerSchemePickerView: View {
    let builtIn: [PrimerSchemeBundle]
    let projectLocal: [PrimerSchemeBundle]
    @Binding var selectedSchemeID: String?
    let onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !builtIn.isEmpty {
                Section {
                    ForEach(builtIn, id: \.manifest.name) { scheme in
                        schemeRow(scheme, badge: "Built-in")
                    }
                } header: {
                    Text("Built-in").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !projectLocal.isEmpty {
                Section {
                    ForEach(projectLocal, id: \.manifest.name) { scheme in
                        schemeRow(scheme, badge: nil)
                    }
                } header: {
                    Text("In this project").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Browse…", action: onBrowse)
        }
    }

    private func schemeRow(_ scheme: PrimerSchemeBundle, badge: String?) -> some View {
        HStack {
            Button(action: { selectedSchemeID = scheme.manifest.name }) {
                HStack {
                    Text(scheme.manifest.displayName)
                    if selectedSchemeID == scheme.manifest.name {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                    Spacer()
                    if let badge { Text(badge).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
