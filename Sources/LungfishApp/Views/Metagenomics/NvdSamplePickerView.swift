// NvdSamplePickerView.swift — SwiftUI popover for NVD sample multi-select
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A sample entry in the NVD picker list.
public struct NvdSampleEntry: Identifiable, Sendable {
    public let id: String  // sample_id
    public let displayName: String  // prefix-stripped name
    public let contigCount: Int
    public let hitCount: Int

    public init(id: String, displayName: String, contigCount: Int, hitCount: Int) {
        self.id = id
        self.displayName = displayName
        self.contigCount = contigCount
        self.hitCount = hitCount
    }
}

/// Observable state object for the NVD sample picker.
///
/// Using `@Observable` instead of a raw `Binding<Set<String>>` ensures that
/// the SwiftUI view inside an `NSHostingController` popover correctly reflects
/// selection changes.
@Observable
public final class NvdSamplePickerState: @unchecked Sendable {
    public var selectedSamples: Set<String> = []
    public init() {}
}

/// SwiftUI popover for selecting NVD samples.
///
/// Shows a searchable, scrollable checklist of samples with contig and hit counts.
/// Common prefixes shared by all samples are stripped from display names.
struct NvdSamplePickerView: View {

    let samples: [NvdSampleEntry]
    @Bindable var pickerState: NvdSamplePickerState
    @State private var searchText: String = ""

    /// Common prefix stripped from display (shown as caption).
    let strippedPrefix: String

    /// When true, the picker fills available space (for Inspector inline embedding).
    /// When false, uses fixed 360x300 sizing (for NSPopover).
    var isInline: Bool = false

    private var filteredSamples: [NvdSampleEntry] {
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
                    ForEach(filteredSamples) { sample in
                        sampleRow(sample)
                    }
                }
            }
            .frame(maxHeight: isInline ? .infinity : 300)
        }
        .frame(width: isInline ? .none : 360)
    }

    private func sampleRow(_ sample: NvdSampleEntry) -> some View {
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

            Text("\(formatNumber(sample.contigCount)) / \(formatNumber(sample.hitCount))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Contigs / Hits")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
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
        // Only strip if it ends at a word boundary (_, -, or end of string)
        if let lastSep = prefix.lastIndex(where: { $0 == "_" || $0 == "-" }) {
            prefix = String(prefix[...lastSep])
        } else {
            prefix = ""
        }
        return prefix
    }
}
