// ClassifierSamplePickerView.swift — Unified sample picker for all classifiers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Unified SwiftUI picker for selecting samples across all classifier types.
///
/// Shows a searchable, scrollable checklist. Each row displays the sample's
/// display name and right-aligned metric value. Supports inline embedding
/// in the Inspector or fixed-size popover from a toolbar button.
struct ClassifierSamplePickerView: View {

    let samples: [any ClassifierSampleEntry]
    @Bindable var pickerState: ClassifierSamplePickerState
    @State private var searchText: String = ""
    let strippedPrefix: String
    var isInline: Bool = false

    private var filteredSamples: [any ClassifierSampleEntry] {
        if searchText.isEmpty { return samples }
        return samples.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var allVisibleSelected: Bool {
        let visibleIds = Set(filteredSamples.map(\.id))
        return !visibleIds.isEmpty && visibleIds.isSubset(of: pickerState.selectedSamples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Filter\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Select All toggle
            HStack {
                Toggle(isOn: Binding(
                    get: { allVisibleSelected },
                    set: { newValue in
                        let visibleIds = Set(filteredSamples.map(\.id))
                        if newValue {
                            pickerState.selectedSamples.formUnion(visibleIds)
                        } else {
                            pickerState.selectedSamples.subtract(visibleIds)
                        }
                    }
                )) {
                    Text("Select All")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)

                Spacer()

                Text("\(samples.count) total")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if !strippedPrefix.isEmpty {
                Text("Prefix: \(strippedPrefix)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            Divider()

            // Sample list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredSamples.indices, id: \.self) { index in
                        sampleRow(filteredSamples[index])
                    }
                }
            }
            .frame(maxHeight: isInline ? .infinity : 300)
        }
        .frame(width: isInline ? nil : 360)
    }

    private func sampleRow(_ sample: any ClassifierSampleEntry) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { pickerState.selectedSamples.contains(sample.id) },
                set: { newValue in
                    if newValue {
                        pickerState.selectedSamples.insert(sample.id)
                    } else {
                        pickerState.selectedSamples.remove(sample.id)
                    }
                }
            )) {
                Text(sample.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)

            Spacer()

            if let secondary = sample.secondaryMetric {
                Text(secondary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(sample.metricLabel)
            } else {
                Text(sample.metricValue)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    /// Computes the longest common prefix across all sample names, breaking at word boundaries.
    static func commonPrefix(of names: [String]) -> String {
        guard let first = names.first, names.count > 1 else { return "" }
        var prefix = first
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix) && !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        if let lastSep = prefix.lastIndex(where: { $0 == "_" || $0 == "-" }) {
            prefix = String(prefix[...lastSep])
        } else {
            prefix = ""
        }
        return prefix
    }
}
