import SwiftUI
import LungfishCore
import LungfishIO

/// SwiftUI section that shows the most-recent audit-log entries from the
/// genotype annotation sidecar. Surfaces who changed what when so consumers
/// reading a shared bundle can see the analyst's annotation history without
/// opening the JSON file. Entries are immutable; deleted entries don't exist.
struct GenotypeAuditTimelineSection: View {
    let entries: [GenotypeAnnotationSidecar.AuditEntry]
    var entryLimit: Int = 10

    private var displayedEntries: [GenotypeAnnotationSidecar.AuditEntry] {
        Array(entries.suffix(entryLimit).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audit timeline")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("No annotations recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(0..<displayedEntries.count, id: \.self) { index in
                    entryRow(displayedEntries[index])
                    if index < displayedEntries.count - 1 {
                        Divider()
                    }
                }
                if entries.count > entryLimit {
                    Text("+ \(entries.count - entryLimit) earlier entries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: GenotypeAnnotationSidecar.AuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayName(for: entry.action))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(shortTimestamp(entry.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(scopeDescription(entry))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let change = changeSummary(entry) {
                Text(change)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func displayName(for action: String) -> String {
        switch action {
        case "override":            return "Override"
        case "undoOverride":        return "Undo override"
        case "setSampleStatus":     return "Status"
        case "setCallStatus":       return "Call status"
        case "setCellHighlight":    return "Highlight"
        case "addCellComment":      return "Comment"
        case "addSampleNote":       return "Sample note"
        default:                    return action.capitalized
        }
    }

    private func scopeDescription(_ entry: GenotypeAnnotationSidecar.AuditEntry) -> String {
        var parts = [entry.sample]
        if let locus = entry.locus { parts.append(locus) }
        if let slot = entry.slot { parts.append(slot.displayName) }
        return parts.joined(separator: " / ")
    }

    private func changeSummary(_ entry: GenotypeAnnotationSidecar.AuditEntry) -> String? {
        if let before = entry.before, let after = entry.after {
            return "\(before) → \(after)"
        }
        if let after = entry.after {
            return "→ \(after)"
        }
        if let color = entry.color {
            return color
        }
        if let rationale = entry.rationale, !rationale.isEmpty {
            return rationale
        }
        return nil
    }

    private func shortTimestamp(_ raw: String) -> String {
        // Show clock time when the entry is today, otherwise YYYY-MM-DD.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else { return raw }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
