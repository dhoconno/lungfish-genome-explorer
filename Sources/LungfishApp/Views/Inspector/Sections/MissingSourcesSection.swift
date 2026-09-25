// MissingSourcesSection.swift - Inspector rows for source data a copied item cannot reach
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An item copied from another project keeps its results but may have lost
// its links to the reads, reference or database it was made from. This
// section names each missing source and where it used to live, in the place
// the user looks first, instead of letting an action fail later.

import LungfishIO
import SwiftUI

struct MissingSourcesSection: View {
    let record: ProjectItemCopyRecord

    @State private var isExpanded = true

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        DisclosureGroup("Source Data Not In This Project", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(originLine)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(record.unresolvedLinks) { link in
                    missingRow(link)
                }

                if record.missingSourceReads {
                    Label(
                        "Actions that need the source reads, such as extracting or verifying reads, are unavailable for this copy.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
            .padding(.top, 4)
            .accessibilityIdentifier("inspector.missingSources")
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private var originLine: String {
        let when = Self.dateFormatter.string(from: record.copiedAt)
        if let project = record.sourceProjectName {
            return "Copied from project \(project) on \(when)."
        }
        return "Copied into this project on \(when)."
    }

    @ViewBuilder
    private func missingRow(_ link: ProjectItemCopyLink) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.secondary)
                Text(link.displayName)
                    .font(LungfishInspectorStyle.controlFont)
                Text(link.role)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
            Text("was \(ProjectItemLinkRewriter.plainPath(from: link.originalPath))")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(ProjectItemLinkRewriter.plainPath(from: link.originalPath))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source data not in this project: \(link.displayName), was \(ProjectItemLinkRewriter.plainPath(from: link.originalPath))")
    }
}
