// NvdImportSheet.swift - SwiftUI dialog for importing NVD results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import LungfishIO

struct ImportPathValidationToken: Sendable {
    let generation: UInt64
    let path: String
}

struct ImportPathValidationGate<Output> {
    private var session = AsyncValidationSession<String, Output>()

    mutating func begin(path: URL) -> ImportPathValidationToken {
        let token = session.begin(input: path.standardizedFileURL.path)
        return ImportPathValidationToken(generation: token.generation, path: token.identity)
    }

    mutating func cancel() {
        session.cancel()
    }

    func shouldAccept(_ token: ImportPathValidationToken) -> Bool {
        session.shouldAccept(resultFor: AsyncRequestToken(
            generation: token.generation,
            identity: token.path
        ))
    }
}

// MARK: - NvdImportSheet

/// A SwiftUI sheet for importing results from the NVD (Novel Virus Diagnostics) pipeline.
///
/// The dialog lets the user browse to an NVD run directory, previews what was found
/// by scanning the `05_labkey_bundling/*_blast_concatenated.csv(.gz)` file, and then
/// triggers import into the current project.
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------+
/// | [Nvd badge]  NVD Import                            |
/// |              Novel Virus Diagnostics  dataset-name |
/// +----------------------------------------------------+
/// | Results Directory                                   |
/// | [  /path/to/nvd-output/              ] [Browse...] |
/// +----------------------------------------------------+
/// | Preview                                             |
/// |   Experiment:    100                                |
/// |   Samples:        4                                 |
/// |   Contigs:      253                                 |
/// |   BLAST hits:  1234                                 |
/// |   Total BAM:   1.2 GB                               |
/// +----------------------------------------------------+
/// |                          [Cancel]  [Run]            |
/// +----------------------------------------------------+
/// ```
///
/// ## Design
///
/// Follows the Lungfish dialog standard:
/// - Header: badge icon + tool name (.headline) + subtitle (.caption)
/// - Dataset name top-right
/// - 500x450 frame
/// - "Run" button (never "Import", "Go", etc.)
struct NvdImportSheet: View {

    /// The dataset URL that triggered this import (for context display).
    let datasetURL: URL?

    /// Called when the user clicks Run. Parameter: NVD run directory URL.
    var onImport: ((URL) -> Void)?

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    // MARK: - State

    @State private var selectedPath: URL? = nil
    @State private var isScanning: Bool = false
    @State private var linesScanned: Int = 0
    @State private var scanError: String? = nil
    @State private var scanValidationGate = ImportPathValidationGate<NvdScanResult>()

    // Preview data from scanning
    @State private var experimentId: String? = nil
    @State private var sampleCount: Int? = nil
    @State private var contigCount: Int? = nil
    @State private var hitCount: Int? = nil
    @State private var totalBAMSize: Int64? = nil

    // MARK: - Computed Properties

    /// Display name for the dataset.
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
                    // Results directory location
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
        .frame(width: 500, height: 450)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(nsImage: TextBadgeIcon.image(text: "NVD", size: NSSize(width: 24, height: 24)))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("NVD Import")
                    .font(.headline)
                Text("Novel Virus Diagnostics")
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
            Text("Results Directory")
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
                    browseForDirectory()
                }
                .font(.system(size: 12))
            }

            Text("Select the top-level NVD run directory (containing 05_labkey_bundling/).")
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
                        Text("Scanning\u{2026} \(formatNumber(linesScanned)) rows")
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
            } else if let hits = hitCount {
                VStack(alignment: .leading, spacing: 4) {
                    if let exp = experimentId, !exp.isEmpty {
                        previewRow(label: "Experiment", value: exp)
                    }
                    if let samples = sampleCount {
                        previewRow(label: "Samples", value: formatNumber(samples))
                    }
                    if let contigs = contigCount {
                        previewRow(label: "Contigs", value: formatNumber(contigs))
                    }
                    previewRow(label: "BLAST hits", value: formatNumber(hits))
                    if let bamSize = totalBAMSize, bamSize > 0 {
                        previewRow(label: "Total BAM size", value: formatBytes(bamSize))
                    }
                }
            } else {
                Text("Select an NVD results directory to preview.")
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
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            if selectedPath == nil {
                Text("No directory selected")
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

    /// Opens an NSOpenPanel to browse for the NVD results directory.
    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Select NVD Results Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the top-level NVD run directory"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            selectedPath = url
            scanDirectory(at: url)
        }
    }

    /// Scans the selected NVD directory for results and populates preview data.
    private func scanDirectory(at url: URL) {
        let scanToken = scanValidationGate.begin(path: url)
        isScanning = true
        scanError = nil
        experimentId = nil
        sampleCount = nil
        contigCount = nil
        hitCount = nil
        totalBAMSize = nil
        linesScanned = 0

        Task {
            do {
                let result = try await nvdScanDirectory(url) { count in
                    Task { @MainActor in
                        guard scanValidationGate.shouldAccept(scanToken) else { return }
                        self.linesScanned = count
                    }
                }

                await MainActor.run {
                    guard scanValidationGate.shouldAccept(scanToken) else { return }
                    experimentId = result.experiment
                    sampleCount = result.sampleCount
                    contigCount = result.contigCount
                    hitCount = result.hitCount
                    totalBAMSize = result.totalBAMSize
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    guard scanValidationGate.shouldAccept(scanToken) else { return }
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

    /// Formats a byte count as human-readable string.
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - NVD Directory Scan

/// Result of scanning an NVD output directory.
private struct NvdScanResult {
    let experiment: String
    let sampleCount: Int
    let contigCount: Int
    let hitCount: Int
    let totalBAMSize: Int64
}

/// Scans an NVD run directory to extract preview metadata.
///
/// This is a free function (not an instance method) to avoid Swift 6 isolation
/// issues with @Sendable closures capturing self.
private func nvdScanDirectory(
    _ url: URL,
    lineProgress: @Sendable (Int) -> Void
) async throws -> NvdScanResult {
    // Find the blast_concatenated.csv(.gz) under 05_labkey_bundling/
    let labkeyDir = url.appendingPathComponent("05_labkey_bundling", isDirectory: true)
    guard FileManager.default.fileExists(atPath: labkeyDir.path) else {
        throw NvdScanError.directoryNotFound("05_labkey_bundling/ not found in selected directory")
    }

    let contents = try FileManager.default.contentsOfDirectory(
        at: labkeyDir,
        includingPropertiesForKeys: nil
    )
    guard let csvURL = contents.first(where: NvdResultParser.isBlastConcatenatedCSV) else {
        throw NvdScanError.csvNotFound("No *_blast_concatenated.csv or *.csv.gz found in 05_labkey_bundling/")
    }

    // Fast-scan the CSV for counts (no full parse)
    var lines: [String] = []
    for try await line in csvURL.linesAutoDecompressing() {
        lines.append(line)
    }
    // Remove trailing empty lines
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeLast()
    }

    guard lines.count > 1 else {
        // Header-only file
        return NvdScanResult(
            experiment: "",
            sampleCount: 0,
            contigCount: 0,
            hitCount: 0,
            totalBAMSize: 0
        )
    }

    // Parse header to find column indices
    let headerFields = csvParseRow(lines[0])
    var colIndex: [String: Int] = [:]
    for (i, header) in headerFields.enumerated() {
        colIndex[header.lowercased()] = i
    }

    guard let experimentCol = colIndex["experiment"],
          let sampleIdCol = colIndex["sample_id"],
          let qseqidCol = colIndex["qseqid"] else {
        throw NvdScanError.invalidHeader("CSV is missing required columns: experiment, sample_id, qseqid")
    }

    var experimentId = ""
    var sampleIds: Set<String> = []
    var qseqids: Set<String> = []
    var dataLineCount = 0

    for (idx, line) in lines.dropFirst().enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        if idx % 1000 == 0 {
            lineProgress(idx + 2)
        }

        let fields = csvParseRow(trimmed)

        if experimentId.isEmpty, experimentCol < fields.count {
            experimentId = fields[experimentCol]
        }
        if sampleIdCol < fields.count {
            sampleIds.insert(fields[sampleIdCol])
        }
        if qseqidCol < fields.count {
            let sampleId = sampleIdCol < fields.count ? fields[sampleIdCol] : ""
            qseqids.insert("\(sampleId)\u{1F}\(fields[qseqidCol])")
        }
        dataLineCount += 1
    }

    lineProgress(lines.count)

    // Compute total BAM size from mapped_reads directory
    let bamDir = url
        .appendingPathComponent("02_human_viruses", isDirectory: true)
        .appendingPathComponent("03_human_virus_results", isDirectory: true)
        .appendingPathComponent("mapped_reads", isDirectory: true)

    var totalBAMSize: Int64 = 0
    if FileManager.default.fileExists(atPath: bamDir.path) {
        let bamContents = (try? FileManager.default.contentsOfDirectory(
            at: bamDir,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        for bamURL in bamContents where bamURL.pathExtension == "bam" {
            let attrs = try? bamURL.resourceValues(forKeys: [.fileSizeKey])
            totalBAMSize += Int64(attrs?.fileSize ?? 0)
        }
    }

    return NvdScanResult(
        experiment: experimentId,
        sampleCount: sampleIds.count,
        contigCount: qseqids.count,
        hitCount: dataLineCount,
        totalBAMSize: totalBAMSize
    )
}

/// Errors thrown while scanning an NVD directory.
private enum NvdScanError: Error, LocalizedError {
    case directoryNotFound(String)
    case csvNotFound(String)
    case invalidHeader(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let msg): return msg
        case .csvNotFound(let msg): return msg
        case .invalidHeader(let msg): return msg
        }
    }
}

/// Parses a single CSV row, handling double-quoted fields that may contain commas.
private func csvParseRow(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var idx = line.startIndex

    while idx < line.endIndex {
        let ch = line[idx]

        if inQuotes {
            if ch == "\"" {
                let next = line.index(after: idx)
                if next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    idx = line.index(after: next)
                    continue
                } else {
                    inQuotes = false
                }
            } else {
                current.append(ch)
            }
        } else {
            if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }

        idx = line.index(after: idx)
    }

    fields.append(current)
    return fields
}
