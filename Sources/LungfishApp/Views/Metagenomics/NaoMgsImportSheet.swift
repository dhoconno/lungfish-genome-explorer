// NaoMgsImportSheet.swift - SwiftUI dialog for importing NAO-MGS results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

// MARK: - NaoMgsImportSheet

/// A SwiftUI sheet for importing results from the SecureBio NAO-MGS
/// metagenomic surveillance workflow.
///
/// The dialog lets the user browse to a results directory (or a single
/// `virus_hits_final.tsv.gz` file), previews what was found, and then
/// triggers import into the current project.
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------+
/// | [globe.americas]  NAO-MGS Import                   |
/// |                   Import metagenomic surveillance   |
/// |                   results              dataset-name |
/// +----------------------------------------------------+
/// | Results Location                                    |
/// | [  /path/to/results/              ] [Browse...]     |
/// +----------------------------------------------------+
/// | Preview                                             |
/// |   Virus hits:     1,234                             |
/// |   Distinct taxa:  42                                |
/// |   Source file:     virus_hits_final.tsv.gz           |
/// +----------------------------------------------------+
/// | Options                                             |
/// |   Min % identity: [---|----90--------]  90%         |
/// +----------------------------------------------------+
/// |                        [Cancel]  [Run]              |
/// +----------------------------------------------------+
/// ```
///
/// ## Design
///
/// Follows the Lungfish dialog standard (see DEVELOPMENT-LEAD-AGENT.md):
/// - Header: tool icon + tool name (.headline) + subtitle (.caption)
/// - Dataset name top-right
/// - 520x480 frame
/// - "Run" button (never "Import", "Go", etc.)
struct NaoMgsImportSheet: View {

    /// The FASTQ bundle URL that triggered this import (for context display).
    let datasetURL: URL?

    /// Called when the user clicks Run. Parameter: results URL.
    var onImport: ((URL) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - State

    @State private var selectedPath: URL? = nil
    @State private var isScanning: Bool = false
    @State private var linesScanned: Int = 0
    @State private var scanError: String? = nil

    // Preview data from scanning
    @State private var hitCount: Int? = nil
    @State private var taxonCount: Int? = nil
    @State private var sourceFileName: String? = nil

    // MARK: - Computed Properties

    /// Display name for the dataset, stripped of `.lungfishfastq`.
    private var datasetDisplayName: String {
        guard let url = datasetURL else { return "" }
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".lungfishfastq") {
            return URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        return name
    }

    /// Whether the Run button should be enabled.
    private var canRun: Bool {
        selectedPath != nil && !isScanning && hitCount != nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Results location
                    locationSection

                    Divider()

                    // Preview
                    previewSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider()

            // Action buttons
            actionButtons
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.americas")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("NAO-MGS Import")
                    .font(.headline)
                Text("Import metagenomic surveillance results")
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

    // MARK: - Location

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results Location")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(selectedPath?.path ?? "No directory selected")
                    .font(.system(size: 12))
                    .foregroundStyle(selectedPath != nil ? .primary : .secondary)
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
                    browseForResults()
                }
                .font(.system(size: 12))
            }

            Text("Select a directory containing virus_hits_final.tsv.gz, or the file directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if linesScanned > 0 {
                        Text("Scanning\u{2026} \(formatNumber(linesScanned)) lines")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scanning results\u{2026}")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = scanError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.1))
                )
            } else if let hits = hitCount, let taxa = taxonCount {
                VStack(alignment: .leading, spacing: 4) {
                    previewRow(label: "Virus hits", value: formatNumber(hits))
                    previewRow(label: "Distinct taxa", value: String(taxa))
                    if let source = sourceFileName {
                        previewRow(label: "Source file", value: source)
                    }
                }
            } else {
                Text("Select a results directory to preview.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A single label-value row in the preview section.
    private func previewRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            if selectedPath == nil {
                Text("No results selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                onCancel?()
            }
            .keyboardShortcut(.cancelAction)

            Button("Run") {
                performImport()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// Opens an NSOpenPanel to browse for results.
    private func browseForResults() {
        let panel = NSOpenPanel()
        panel.title = "Select NAO-MGS Results"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data, .folder]
        panel.message = "Select a virus_hits_final.tsv.gz file or results directory"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            selectedPath = url
            scanResults(at: url)
        }
    }

    /// Scans the selected path for NAO-MGS results and populates preview data.
    private func scanResults(at url: URL) {
        isScanning = true
        scanError = nil
        hitCount = nil
        taxonCount = nil
        sourceFileName = nil
        linesScanned = 0

        Task {
            do {
                let parser = NaoMgsResultParser()

                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

                let result: NaoMgsResult
                if isDir.boolValue {
                    result = try await parser.loadResults(from: url) { count in
                        Task { @MainActor in
                            self.linesScanned = count
                        }
                    }
                } else {
                    let hits = try await parser.parseVirusHits(at: url) { count in
                        Task { @MainActor in
                            self.linesScanned = count
                        }
                    }
                    let summaries = parser.aggregateByTaxon(hits)
                    result = NaoMgsResult(
                        virusHits: hits,
                        taxonSummaries: summaries,
                        totalHitReads: hits.count,
                        sampleName: hits.first?.sample ?? url.deletingPathExtension()
                            .deletingPathExtension().lastPathComponent,
                        sourceDirectory: url.deletingLastPathComponent(),
                        virusHitsFile: url
                    )
                }

                await MainActor.run {
                    hitCount = result.totalHitReads
                    taxonCount = result.taxonSummaries.count
                    sourceFileName = result.virusHitsFile.lastPathComponent
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    isScanning = false
                }
            }
        }
    }

    /// Triggers the import callback with the current configuration.
    private func performImport() {
        guard let url = selectedPath else { return }
        onImport?(url)
    }

    // MARK: - Formatting

    /// Formats an integer with thousands separators.
    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
