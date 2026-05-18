// CzIdImportSheet.swift - SwiftUI dialog for importing CZ-ID results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishWorkflow

struct CzIdImportDialogPresentation: Equatable {
    let selectedPathText: String
    let selectedPathIsPlaceholder: Bool
    let accessoryText: String?
    let destinationText: String
    let statusText: String
    let statusColor: Color
    let isPrimaryEnabled: Bool

    init(
        selectedPath: URL?,
        isScanning: Bool,
        scanError: String?,
        preview: CzIdImportPreview?,
        projectURL: URL?,
        datasetURL: URL?
    ) {
        self.selectedPathText = selectedPath?.path ?? "No file or folder selected"
        self.selectedPathIsPlaceholder = selectedPath == nil
        self.accessoryText = datasetURL?.deletingPathExtension().lastPathComponent
        self.destinationText = Self.destinationText(projectURL: projectURL)
        self.isPrimaryEnabled = selectedPath != nil && preview != nil && !isScanning

        if isScanning {
            self.statusText = "Scanning CZ-ID export..."
            self.statusColor = .secondary
        } else if let scanError, !scanError.isEmpty {
            self.statusText = scanError
            self.statusColor = .orange
        } else if isPrimaryEnabled {
            self.statusText = "Ready to import CZ-ID report."
            self.statusColor = .secondary
        } else {
            self.statusText = "Select a CZ-ID export."
            self.statusColor = .secondary
        }
    }

    private static func destinationText(projectURL: URL?) -> String {
        guard let projectURL else { return "Current project / Analyses" }
        return projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("cz-id-\(timestampHint)")
            .path
    }

    private static var timestampHint: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: Date())
    }

    static func == (lhs: CzIdImportDialogPresentation, rhs: CzIdImportDialogPresentation) -> Bool {
        lhs.selectedPathText == rhs.selectedPathText
            && lhs.selectedPathIsPlaceholder == rhs.selectedPathIsPlaceholder
            && lhs.accessoryText == rhs.accessoryText
            && lhs.destinationText == rhs.destinationText
            && lhs.statusText == rhs.statusText
            && lhs.isPrimaryEnabled == rhs.isPrimaryEnabled
    }
}

enum CzIdImportDialogActions {
    static func importIfReady(
        selectedPath: URL?,
        isPrimaryEnabled: Bool,
        onImport: ((URL) -> Void)?
    ) {
        guard isPrimaryEnabled, let selectedPath else { return }
        onImport?(selectedPath)
    }

    static func cancel(
        cancelScan: () -> Void,
        onCancel: (() -> Void)?
    ) {
        cancelScan()
        onCancel?()
    }
}

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

    private var presentation: CzIdImportDialogPresentation {
        CzIdImportDialogPresentation(
            selectedPath: selectedPath,
            isScanning: isScanning,
            scanError: scanError,
            preview: preview,
            projectURL: projectURL,
            datasetURL: datasetURL
        )
    }

    var body: some View {
        ImportSheet(
            title: "CZ-ID Import",
            subtitle: "Hosted metagenomics taxon report",
            accessoryText: presentation.accessoryText,
            size: ImportSheetSize(width: 520, height: 460),
            statusText: presentation.statusText,
            statusColor: presentation.statusColor,
            primaryTitle: "Run",
            isPrimaryEnabled: presentation.isPrimaryEnabled,
            onCancel: cancelImport,
            onPrimary: runImport,
            icon: {
                Image(nsImage: TextBadgeIcon.image(text: "CZ", size: NSSize(width: 24, height: 24)))
                    .resizable()
                    .frame(width: 24, height: 24)
            },
            content: {
                contentSections
            }
        )
        .accessibilityIdentifier("czid-import-sheet")
        .help("dialog.CzIdImportSheet")
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            locationSection
            Divider()
            previewSection
            Divider()
            destinationSection
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CZ-ID Export")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(presentation.selectedPathText)
                    .font(.system(size: 12))
                    .foregroundStyle(presentation.selectedPathIsPlaceholder ? .secondary : .primary)
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
            Text(presentation.destinationText)
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
        let panel = MetagenomicsFilePanelFactory.czIdExportImportPanel()

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

    private func cancelImport() {
        CzIdImportDialogActions.cancel(
            cancelScan: { scanValidationGate.cancel() },
            onCancel: onCancel
        )
    }

    private func runImport() {
        CzIdImportDialogActions.importIfReady(
            selectedPath: selectedPath,
            isPrimaryEnabled: presentation.isPrimaryEnabled,
            onImport: onImport
        )
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

}
