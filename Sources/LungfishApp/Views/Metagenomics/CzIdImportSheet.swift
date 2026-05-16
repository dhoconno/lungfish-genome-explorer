// CzIdImportSheet.swift - SwiftUI dialog for importing CZ-ID results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CzIdImportSheet: View {
    let projectURL: URL?
    let datasetURL: URL?
    var onImport: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    @State private var selectedPath: URL?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var preview: CzIdImportPreview?
    @State private var scanValidationGate = ImportPathValidationGate<CzIdImportPreview>()

    private var datasetDisplayName: String {
        guard let url = datasetURL else { return "" }
        return url.deletingPathExtension().lastPathComponent
    }

    private var destinationText: String {
        guard let projectURL else { return "Current project / Analyses" }
        return projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("cz-id-\(CzIdImportSheet.timestampHint)")
            .path
    }

    private var canRun: Bool {
        selectedPath != nil && preview != nil && !isScanning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    locationSection
                    Divider()
                    previewSection
                    Divider()
                    destinationSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            Divider()
            actionButtons
        }
        .frame(width: 520, height: 460)
        .accessibilityIdentifier("czid-import-sheet")
        .help("dialog.CzIdImportSheet")
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(nsImage: TextBadgeIcon.image(text: "CZ", size: NSSize(width: 24, height: 24)))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("CZ-ID Import")
                    .font(.headline)
                Text("Hosted metagenomics taxon report")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !datasetDisplayName.isEmpty {
                Text(datasetDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CZ-ID Export")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(selectedPath?.path ?? "No file or folder selected")
                    .font(.system(size: 12))
                    .foregroundStyle(selectedPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                Button("Browse\u{2026}") {
                    browseForSource()
                }
                .font(.system(size: 12))
            }

            Text("Select a CZ-ID taxon report TSV, a ZIP export, or an extracted export folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning CZ-ID export\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if let scanError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 12))
                    Text(scanError)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.1))
                )
            } else if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    previewRow(label: "Sample", value: preview.sampleName)
                    if let projectId = preview.projectId, !projectId.isEmpty {
                        previewRow(label: "Project", value: projectId)
                    }
                    previewRow(label: "Rows", value: Self.numberFormatter.string(from: NSNumber(value: preview.rowCount)) ?? "\(preview.rowCount)")
                    previewRow(label: "Source", value: preview.sourceKind.displayName)
                    previewRow(label: "Report", value: preview.reportFileName)
                    if let pipelineVersion = preview.pipelineVersion, !pipelineVersion.isEmpty {
                        previewRow(label: "Pipeline", value: pipelineVersion)
                    }
                    if let nt = preview.ntDatabaseVersion, !nt.isEmpty {
                        previewRow(label: "NT DB", value: nt)
                    }
                    if let nr = preview.nrDatabaseVersion, !nr.isEmpty {
                        previewRow(label: "NR DB", value: nr)
                    }
                    if !preview.topTaxa.isEmpty {
                        previewRow(
                            label: "Top taxa",
                            value: preview.topTaxa.map(\.name).joined(separator: ", ")
                        )
                    }
                }
            } else {
                Text("Select a CZ-ID export to preview sample metadata and taxon rows.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Destination")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(destinationText)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                scanValidationGate.cancel()
                onCancel?()
            }
            .keyboardShortcut(.cancelAction)

            Button("Run") {
                guard let selectedPath, canRun else { return }
                onImport?(selectedPath)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func previewRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func browseForSource() {
        let panel = NSOpenPanel()
        panel.title = "Select CZ-ID Export"
        panel.message = "Select a CZ-ID taxon report TSV, ZIP archive, or extracted folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "zip") ?? .zip,
            UTType(filenameExtension: "tsv") ?? .tabSeparatedText,
            UTType(filenameExtension: "txt") ?? .plainText,
            UTType(filenameExtension: "csv") ?? .commaSeparatedText,
        ]
        panel.allowsOtherFileTypes = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            selectedPath = url
            scan(url)
        }
    }

    private func scan(_ url: URL) {
        let token = scanValidationGate.begin(path: url)
        isScanning = true
        scanError = nil
        preview = nil

        Task {
            do {
                let result = try await CzIdImportPreview.scan(url)
                await MainActor.run {
                    guard scanValidationGate.shouldAccept(token) else { return }
                    preview = result
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    guard scanValidationGate.shouldAccept(token) else { return }
                    scanError = error.localizedDescription
                    isScanning = false
                }
            }
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static var timestampHint: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }
}
