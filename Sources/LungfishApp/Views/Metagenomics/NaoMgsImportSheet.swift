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
/// `virus_hits_final.tsv.gz` file), validates the header, and then
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
/// | Validation                                          |
/// |   Valid NAO-MGS results                             |
/// |   Source file:     virus_hits_final.tsv.gz           |
/// |   8 per-lane files                                  |
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
///
/// ## Performance
///
/// Validation reads only the first line (header) of the TSV file.
/// For gzip-compressed files a short-lived `gzip -dc` process reads a
/// single 8 KB chunk and is immediately terminated, so even multi-GB
/// compressed files validate in under a second with negligible RAM.
struct NaoMgsImportSheet: View {

    /// The FASTQ bundle URL that triggered this import (for context display).
    let datasetURL: URL?

    /// Called when the user clicks Run. Parameter: results URL.
    var onImport: ((URL) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - State

    @State private var selectedPath: URL? = nil
    @State private var isValidating: Bool = false
    @State private var scanError: String? = nil
    @State private var validationGate = ImportPathValidationGate<Bool>()

    // Lightweight validation results (no full parse)
    @State private var headerValid: Bool = false
    @State private var fileCount: Int = 0
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
        selectedPath != nil && !isValidating && headerValid
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

                    // Validation status
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
            Image(nsImage: TextBadgeIcon.image(text: "NM", size: NSSize(width: 24, height: 24)))
                .resizable()
                .frame(width: 24, height: 24)
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

    // MARK: - Preview / Validation

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Validation")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if isValidating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
            } else if headerValid {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text("Valid NAO-MGS results")
                            .font(.system(size: 12, weight: .medium))
                    }
                    if let source = sourceFileName {
                        previewRow(label: "Source file", value: source)
                    }
                    if fileCount > 1 {
                        previewRow(
                            label: "Files found",
                            value: "\(fileCount) per-lane files"
                        )
                    }
                }
            } else {
                Text("Select a results directory to validate.")
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
            validateResults(at: url)
        }
    }

    /// Validates the selected path by reading only the TSV header line.
    ///
    /// For a single file, reads the first line and checks for required columns.
    /// For a directory, scans for `*virus_hits*.tsv*` files, validates the
    /// header of the first match, and reports the total count.
    private func validateResults(at url: URL) {
        let validationToken = validationGate.begin(path: url)
        isValidating = true
        scanError = nil
        headerValid = false
        fileCount = 0
        sourceFileName = nil

        Task {
            do {
                let parser = NaoMgsResultParser()
                let fm = FileManager.default

                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)

                if isDir.boolValue {
                    // Directory: scan for virus_hits TSV files
                    let matchingFiles = findVirusHitsFiles(in: url)

                    guard let firstFile = matchingFiles.first else {
                        throw NaoMgsError.missingResultFiles(url)
                    }

                    _ = try await parser.validateHeader(at: firstFile)

                    await MainActor.run {
                        guard validationGate.shouldAccept(validationToken) else { return }
                        headerValid = true
                        fileCount = matchingFiles.count
                        sourceFileName = firstFile.lastPathComponent
                        isValidating = false
                    }
                } else {
                    // Single file: validate header directly
                    _ = try await parser.validateHeader(at: url)

                    await MainActor.run {
                        guard validationGate.shouldAccept(validationToken) else { return }
                        headerValid = true
                        fileCount = 1
                        sourceFileName = url.lastPathComponent
                        isValidating = false
                    }
                }
            } catch {
                await MainActor.run {
                    guard validationGate.shouldAccept(validationToken) else { return }
                    scanError = error.localizedDescription
                    isValidating = false
                }
            }
        }
    }

    /// Scans a directory for NAO-MGS virus-hits TSV files.
    ///
    /// Matches both the standard `virus_hits_final.tsv.gz` name and
    /// per-lane patterns like `*_virus_hits.tsv.gz`.
    private func findVirusHitsFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.contains("virus_hits")
                    && (name.hasSuffix(".tsv") || name.hasSuffix(".tsv.gz"))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Triggers the import callback with the current configuration.
    private func performImport() {
        guard let url = selectedPath else { return }
        onImport?(url)
    }
}
