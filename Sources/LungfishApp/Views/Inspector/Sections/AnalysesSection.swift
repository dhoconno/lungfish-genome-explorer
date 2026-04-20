// AnalysesSection.swift - Analysis history display for Inspector Document tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

// MARK: - AnalysesSection

/// SwiftUI section displaying analysis history for a FASTQ bundle in the Inspector.
///
/// Shows each analysis run with its tool icon, name, relative timestamp, summary,
/// and key parameters. Tapping an entry invokes the optional `onNavigate` callback.
struct AnalysesSection: View {
    let analyses: [AnalysisManifestEntry]
    var onNavigate: ((AnalysisManifestEntry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if analyses.isEmpty {
                Text("No analyses performed yet. Use the Operations panel to run classifications, assemblies, or mappings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(analyses) { entry in
                    AnalysisRowButton(entry: entry) {
                        onNavigate?(entry)
                    }
                    if entry.id != analyses.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - AnalysisRowButton

/// Wraps an AnalysisRow with hover/click styling to make it look interactive.
private struct AnalysisRowButton: View {
    let entry: AnalysisManifestEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        AnalysisRow(entry: entry, isHovering: isHovering)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - AnalysisRow

/// A single row in the analyses section, showing tool icon, name, timestamp, and summary.
private struct AnalysisRow: View {
    let entry: AnalysisManifestEntry
    var isHovering: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Tool icon
            Image(systemName: iconName(for: entry.tool))
                .font(.title3)
                .foregroundStyle(iconColor(for: entry.tool))
                .frame(width: 24, height: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                // Display name + timestamp
                HStack {
                    Text(entry.displayName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    Text(isHovering ? absoluteTimestamp(entry.timestamp) : relativeTimestamp(entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Summary line
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Parameters line
                let paramString = formattedParameters(entry.parameters)
                if !paramString.isEmpty {
                    Text(paramString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // Status badge for failed analyses
                if entry.status == .failed {
                    Text("Failed")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tool Icon Mapping

    private func iconName(for tool: String) -> String {
        switch tool.lowercased() {
        case "kraken2": return "k.circle.fill"
        case "esviritu": return "e.circle.fill"
        case "taxtriage": return "t.circle.fill"
        case "naomgs": return "n.circle.fill"
        case "spades", "megahit", "skesa", "flye", "hifiasm": return "s.circle.fill"
        case "minimap2", "bwa-mem2", "bowtie2", "bbmap": return "m.circle.fill"
        default: return "gearshape.fill"
        }
    }

    private func iconColor(for tool: String) -> Color {
        .lungfishOrangeFallback
    }

    // MARK: - Timestamp Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func relativeTimestamp(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTimestamp(_ date: Date) -> String {
        Self.absoluteFormatter.string(from: date)
    }

    // MARK: - Parameter Formatting

    private func formattedParameters(_ params: [String: AnalysisParameterValue]) -> String {
        guard !params.isEmpty else { return "" }

        let parts: [String] = params.sorted(by: { $0.key < $1.key }).compactMap { key, value in
            let displayValue: String
            switch value {
            case .bool(let v): displayValue = v ? "yes" : "no"
            case .int(let v): displayValue = "\(v)"
            case .double(let v): displayValue = String(format: "%.1f", v)
            case .string(let v): displayValue = v
            }
            return "\(key): \(displayValue)"
        }

        return parts.joined(separator: " | ")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Analyses Section") {
    ScrollView {
        AnalysesSection(analyses: [
            AnalysisManifestEntry(
                tool: "kraken2",
                analysisDirectoryName: "classification-kraken2-20240601-120000",
                displayName: "Kraken2 Classification",
                parameters: ["confidence": .double(0.2), "database": .string("standard")],
                summary: "1,234 reads classified (98.5%)"
            ),
            AnalysisManifestEntry(
                tool: "spades",
                timestamp: Date().addingTimeInterval(-86400),
                analysisDirectoryName: "assembly-spades-20240531-100000",
                displayName: "SPAdes Assembly",
                summary: "42 contigs, N50: 15,234 bp"
            ),
            AnalysisManifestEntry(
                tool: "minimap2",
                timestamp: Date().addingTimeInterval(-172800),
                analysisDirectoryName: "alignment-minimap2-20240530-090000",
                displayName: "minimap2 Alignment",
                parameters: ["preset": .string("map-ont")],
                summary: "99.2% mapped, 1.2x coverage",
                status: .failed
            ),
        ])
        .padding()
    }
    .frame(width: 280, height: 400)
}

#Preview("Analyses Section - Empty") {
    ScrollView {
        AnalysesSection(analyses: [])
            .padding()
    }
    .frame(width: 280, height: 200)
}
#endif
