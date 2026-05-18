// AttachmentsSection.swift — Inspector section for file attachments
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import AppKit

/// Inspector section displaying file attachments with add/remove/reveal actions.
struct AttachmentsSection: View {
    @Bindable var store: BundleAttachmentStore
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Attachments", isExpanded: $isExpanded) {
            if store.attachments.isEmpty {
                Text("No files attached")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(store.attachments, id: \.filename) { attachment in
                    attachmentRow(attachment)
                }
            }

            Button("Attach File\u{2026}") {
                attachFile()
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    private func attachmentRow(_ attachment: BundleAttachment) -> some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                .resizable()
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatFileSize(attachment.fileSize))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
            }
            Button("Quick Look") {
                NSWorkspace.shared.open(attachment.url)
            }
            Divider()
            Button("Remove Attachment") {
                try? store.remove(filename: attachment.filename)
            }
        }
    }

    private func attachFile() {
        let panel = FeatureFilePanelFactory.attachmentImportPanel()
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                try? store.attach(fileAt: url)
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
