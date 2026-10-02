import AppKit
import SwiftUI
import LungfishCore

struct DatabaseSearchResultRow: View {
    let record: SearchResultRecord
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.lungfishCreamsicleFallback : Color.lungfishSecondaryText)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(record.accession)
                            .font(.headline.monospaced())
                        if let sourceDatabase = record.sourceDatabase, !sourceDatabase.isEmpty {
                            Text(sourceDatabase)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.lungfishSecondaryText)
                        }
                        Spacer()
                        if let length = record.length {
                            Text("\(length) bp")
                                .font(.caption)
                                .foregroundStyle(Color.lungfishSecondaryText)
                        }
                    }

                    Text(record.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let organism = record.organism, !organism.isEmpty {
                        Text(organism)
                            .font(.caption)
                            .foregroundStyle(Color.lungfishSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("database-search-result-\(record.accession)")
    }
}
