// BatchOperationDetailsSection.swift - Inspector section for batch operation details
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

// MARK: - BatchOperationDetailsSection

/// Inspector section showing the tool name, timestamp, and parameters for a batch operation.
///
/// Displayed in the Result Summary inspector tab when a batch group is selected in the sidebar.
struct BatchOperationDetailsSection: View {
    let tool: String
    let parameters: [String: String]
    let timestamp: Date?
    var manifestStatus: DocumentSectionViewModel.BatchManifestStatus = .notCached

    @State private var isExpanded = true

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        DisclosureGroup("Operation Details", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                detailRow("Tool", value: tool)

                if let ts = timestamp {
                    detailRow("Run", value: Self.absoluteFormatter.string(from: ts))
                }

                if !parameters.isEmpty {
                    Divider()
                        .padding(.vertical, 2)

                    ForEach(parameters.keys.sorted(), id: \.self) { key in
                        if let value = parameters[key] {
                            detailRow(key, value: value)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                manifestStatusRow
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private var manifestStatusRow: some View {
        let (iconName, color, label): (String, Color, String) = {
            switch manifestStatus {
            case .cached:
                return ("checkmark.circle.fill", .green, "Manifest cached")
            case .building:
                return ("clock.fill", .orange, "Building manifest...")
            case .notCached:
                return ("circle", Color.secondary, "Not cached")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundStyle(color)
                .font(.system(size: 10))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Batch Operation Details") {
    ScrollView {
        BatchOperationDetailsSection(
            tool: "Kraken2",
            parameters: [
                "Database": "standard-2024-01",
                "Confidence": "0.2",
                "Paired-end": "yes",
            ],
            timestamp: Date()
        )
        .padding()
    }
    .frame(width: 280, height: 200)
}

#Preview("No Parameters") {
    ScrollView {
        BatchOperationDetailsSection(
            tool: "EsViritu",
            parameters: [:],
            timestamp: nil
        )
        .padding()
    }
    .frame(width: 280, height: 100)
}
#endif
