// PrimerSchemeImportView.swift - SwiftUI form driving PrimerSchemeImportViewModel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LungfishCore
import LungfishIO

/// Minimal form that collects the inputs for a user-authored primer-scheme
/// bundle and invokes ``PrimerSchemeImportViewModel/performImport``.
///
/// Presented as a sheet from the Import Center when the user picks the
/// "Primer Scheme" card under the Reference Sequences tab.
struct PrimerSchemeImportView: View {
    @Bindable var viewModel: PrimerSchemeImportViewModel
    let projectURL: URL
    let windowStateScope: WindowStateScope?
    let onComplete: (PrimerSchemeImportViewModel.ImportResult) -> Void
    let onCancel: () -> Void

    @State private var bedURL: URL?
    @State private var fastaURL: URL?
    @State private var name: String = ""
    @State private var displayName: String = ""
    @State private var canonicalAccession: String = ""
    @State private var equivalentAccessionsText: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Primer Scheme")
                .font(.headline)

            Form {
                Section(header: Text("Files").font(.subheadline)) {
                    filePickerRow(
                        title: "BED",
                        url: bedURL,
                        placeholder: "Required — primer coordinates."
                    ) {
                        pickFile(types: ["bed"]) { bedURL = $0 }
                    }
                    filePickerRow(
                        title: "FASTA (optional)",
                        url: fastaURL,
                        placeholder: "Optional — primer sequences."
                    ) {
                        pickFile(types: ["fa", "fasta", "fna"]) { fastaURL = $0 }
                    }
                }

                Section(header: Text("Identity").font(.subheadline)) {
                    TextField("Name (file-safe, e.g. QIASeqDIRECT-SARS2)", text: $name)
                    TextField("Display name (e.g. QIAseq Direct SARS-CoV-2)", text: $displayName)
                    TextField("Canonical reference accession (e.g. MN908947.3)", text: $canonicalAccession)
                    TextField(
                        "Equivalent accessions (comma-separated; optional)",
                        text: $equivalentAccessionsText
                    )
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Import") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var canRun: Bool {
        bedURL != nil &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !canonicalAccession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runImport() {
        guard let bedURL else { return }
        errorMessage = nil
        guard AppDelegate.shared?.canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: windowStateScope,
            workflowName: "Primer scheme import"
        ) ?? true else { return }
        do {
            let equivalents = equivalentAccessionsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let result = try viewModel.performImport(
                bedURL: bedURL,
                fastaURL: fastaURL,
                attachments: [],
                name: name,
                displayName: displayName,
                canonicalAccession: canonicalAccession,
                equivalentAccessions: equivalents,
                projectURL: projectURL
            )
            onComplete(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func filePickerRow(
        title: String,
        url: URL?,
        placeholder: String,
        pick: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .trailing)
            Text(url?.lastPathComponent ?? placeholder)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…") { pick() }
        }
    }

    private func pickFile(types: [String], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
}
