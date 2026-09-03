import AppKit
import SwiftUI

/// One catalogued Viral Recon output as the Inspector presents it.
///
/// `detail` is not decoration. The file names the pipeline writes are named for
/// the tool that produced them, not for the question they answer, so a bench
/// scientist reading `S1.demix.tsv` has no way to know it is the mixture
/// breakdown. The label says what it is; the detail says what it is for.
struct ViralReconDocumentFileRow: Equatable {
    let label: String
    let detail: String
    let fileURL: URL
}

/// A group of outputs that answer the same question.
struct ViralReconDocumentFileSection: Equatable {
    let title: String
    let rows: [ViralReconDocumentFileRow]
}

struct ViralReconDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let sections: [ViralReconDocumentFileSection]
}

/// Lists a completed Viral Recon run's outputs and opens them.
///
/// Rendered above the reference bundle's own metadata rather than instead of
/// it: the run's alignment and variant tracks live in that bundle, so replacing
/// its content the way the mapping document does would hide the tracks this
/// catalogue is describing.
struct ViralReconDocumentSection: View {
    let state: ViralReconDocumentState

    @State private var collapsedSections: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ForEach(state.sections, id: \.title) { section in
                Divider()
                fileSection(section)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(.headline)
            if let subtitle = state.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileSection(_ section: ViralReconDocumentFileSection) -> some View {
        DisclosureGroup(
            section.title,
            isExpanded: Binding(
                get: { !collapsedSections.contains(section.title) },
                set: { isExpanded in
                    if isExpanded {
                        collapsedSections.remove(section.title)
                    } else {
                        collapsedSections.insert(section.title)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.rows, id: \.fileURL) { row in
                    fileRow(row)
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private func fileRow(_ row: ViralReconDocumentFileRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Opening beats revealing here: these are terminal artifacts a user
            // wants to read (a report in a browser, a table in a spreadsheet),
            // not inputs they want to locate on disk.
            Button(row.label) {
                NSWorkspace.shared.open(row.fileURL)
            }
            .buttonStyle(.link)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(rowIdentifier(for: row.label))
            .help("Open \(row.fileURL.lastPathComponent)")

            Text(row.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.fileURL.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.fileURL.path)
        }
    }

    private func rowIdentifier(for label: String) -> String {
        let slug = label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "viralrecon-output-\(slug)"
    }
}
