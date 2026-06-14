// BAMPrimerTrimToolPanes.swift - Inner panes for the BAM primer-trim dialog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import Observation
import LungfishKit

/// Inner panes for the primer-trim dialog: scheme picker, advanced options,
/// and readiness summary stacked inside a scroll view.
struct BAMPrimerTrimToolPanes: View {
    @Bindable var state: BAMPrimerTrimDialogState
    let onBrowseScheme: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewSection
                targetSection
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
                selectedSchemeID: Binding(
                    get: { state.selectedSchemeID },
                    set: { newValue in
                        if let newValue {
                            state.selectScheme(id: newValue)
                        } else {
                            state.selectedSchemeID = nil
                        }
                    }
                ),
                onBrowse: onBrowseScheme
            )
            .lungfishHelp(LungfishHelpContent.bamPrimerScheme)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target").font(.headline)

            Picker("Alignment Track", selection: Binding(
                get: { state.alignmentTrackID ?? "" },
                set: { state.selectAlignmentTrack(id: $0) }
            )) {
                ForEach(state.alignmentTrackOptions, id: \.id) { track in
                    Text(track.name).tag(track.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(state.alignmentTrackOptions.isEmpty)
            .lungfishHelp(LungfishHelpContent.bamPrimerTrimAlignmentTrack)

            TextField("Output Track Name", text: $state.outputTrackName)
                .textFieldStyle(.roundedBorder)
                .lungfishHelp(LungfishHelpContent.bamPrimerTrimOutputTrack)

            Text("Reads without matching primers are retained; review downstream QC before variant calling.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lungfishHelp(LungfishHelpContent.bamPrimerTrimRetainsUnmatchedReads)
        }
    }

    private var advancedOptionsSection: some View {
        DisclosureGroup("Advanced Options") {
            VStack(alignment: .leading, spacing: 12) {
                labeledField("Minimum read length after trim", placeholder: "30", text: $state.minReadLengthText)
                    .lungfishHelp(LungfishHelpContent.bamPrimerTrimMinReadLength)
                labeledField("Minimum quality", placeholder: "20", text: $state.minQualityText)
                    .lungfishHelp(LungfishHelpContent.bamPrimerTrimMinQuality)
                labeledField("Sliding window width", placeholder: "4", text: $state.slidingWindowText)
                    .lungfishHelp(LungfishHelpContent.bamPrimerTrimSlidingWindow)
                labeledField("Primer offset", placeholder: "0", text: $state.primerOffsetText)
                    .lungfishHelp(LungfishHelpContent.bamPrimerTrimOffset)
            }
        }
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readiness").font(.headline)
            Text(state.readinessText)
                .foregroundStyle(.secondary)
                .lungfishHelp(LungfishHelpContent.operationReadiness)
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
