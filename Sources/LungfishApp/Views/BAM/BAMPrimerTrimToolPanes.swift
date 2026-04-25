// BAMPrimerTrimToolPanes.swift - Inner panes for the BAM primer-trim dialog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import Observation

/// Inner panes for the primer-trim dialog: scheme picker, advanced options,
/// and readiness summary stacked inside a scroll view.
struct BAMPrimerTrimToolPanes: View {
    @Bindable var state: BAMPrimerTrimDialogState
    let onBrowseScheme: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewSection
                advancedOptionsSection
                readinessSection
            }
            .padding()
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Primer Scheme").font(.headline)
            PrimerSchemePickerView(
                builtIn: state.builtInSchemes,
                projectLocal: state.projectSchemes,
                selectedSchemeID: $state.selectedSchemeID,
                onBrowse: onBrowseScheme
            )
        }
    }

    private var advancedOptionsSection: some View {
        DisclosureGroup("Advanced Options") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("Minimum read length after trim", text: $state.minReadLengthText)
                labeledField("Minimum quality", text: $state.minQualityText)
                labeledField("Sliding window width", text: $state.slidingWindowText)
                labeledField("Primer offset", text: $state.primerOffsetText)
            }
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness").font(.headline)
            Text(state.readinessText).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }
}
