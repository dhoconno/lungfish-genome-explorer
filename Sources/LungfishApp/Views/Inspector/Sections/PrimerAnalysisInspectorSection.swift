import AppKit
import SwiftUI
import LungfishIO

struct PrimerAnalysisInspectorFile: Identifiable {
    var id: String { artifact.relativePath }
    let artifact: PrimerAnalysisArtifact
    let url: URL
}

struct PrimerAnalysisInspectorDocument {
    let bundleURL: URL
    var isLoading = true
    var errorMessage: String?
    var grouping = ""
    var inputCount = 0
    var resultCount = 0
    var toolDescriptions: [String] = []
    var files: [PrimerAnalysisInspectorFile] = []
    var order: PrimerOrderDocument?
    var isOrder = false

    var title: String { bundleURL.deletingPathExtension().lastPathComponent }
}

struct PrimerAnalysisInspectorBundleSection: View {
    let document: PrimerAnalysisInspectorDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.title).font(LungfishInspectorStyle.sectionTitleFont)
                .textSelection(.enabled)
            Text(document.isOrder ? "Primer Order" : "Primer Analysis").foregroundStyle(.secondary)
            if document.isLoading {
                ProgressView("Verifying saved analysis…")
            } else if let error = document.errorMessage {
                Label("Analysis unavailable", systemImage: "exclamationmark.triangle")
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Divider()
                if let order = document.order {
                    LabeledContent("Oligos", value: String(order.oligos.count))
                    LabeledContent("Pools", value: String(Set(order.oligos.map(\.poolName)).count))
                    LabeledContent("Captured", value: order.selection.capturedAt.formatted())
                    ForEach([("Requested by", order.metadata.requestedBy), ("Project", order.metadata.project),
                        ("Order reference", order.metadata.orderReference), ("Notes", order.metadata.notes)], id: \.0) { label, value in
                        if !value.isEmpty { LabeledContent(label, value: value).textSelection(.enabled) }
                    }
                    Text("Displayed oligos captured from the Inspector. Original design retained; this subset has not been redesigned or validated as a complete scheme.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Grouping", value: document.grouping)
                    LabeledContent("Inputs", value: String(document.inputCount))
                    LabeledContent("Results", value: String(document.resultCount))
                    ForEach(document.toolDescriptions, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
            Divider()
            Button(document.isOrder ? "Reveal Order in Finder" : "Reveal Bundle in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([document.bundleURL])
            }.buttonStyle(.link)
            Text(document.bundleURL.path).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .font(LungfishInspectorStyle.controlFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("primerAnalysisInspector.bundle")
    }
}

struct PrimerAnalysisInspectorFilesSection: View {
    let document: PrimerAnalysisInspectorDocument
    @State private var searchText = ""

    private var matchingFiles: [PrimerAnalysisInspectorFile] {
        document.files.filter {
            searchText.isEmpty || "\($0.artifact.relativePath) \($0.artifact.role) \($0.artifact.format)"
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files").font(LungfishInspectorStyle.sectionTitleFont)
            if document.isLoading {
                ProgressView("Verifying saved files…")
            } else if let error = document.errorMessage {
                Text("Files are unavailable because the saved analysis could not be verified.")
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(document.isOrder
                    ? "\(document.files.count) verified files, including order sheets, template and retained source evidence."
                    : "\(document.files.count) verified payloads, including inputs, native outputs and provenance.")
                    .foregroundStyle(.secondary)
                TextField("Filter files", text: $searchText).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("primerAnalysisInspector.fileFilter")
                ForEach(matchingFiles) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(file.artifact.relativePath) {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        }
                        .buttonStyle(.link)
                        .help("Reveal in Finder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(file.artifact.role) • \(file.artifact.format) • \(ByteCountFormatter.string(fromByteCount: Int64(clamping: file.artifact.byteSize), countStyle: .file))")
                            .foregroundStyle(.secondary)
                        DisclosureGroup("SHA-256") {
                            Text(file.artifact.sha256).textSelection(.enabled)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                    Divider()
                }
                if matchingFiles.isEmpty { Text("No files match this filter.").foregroundStyle(.secondary) }
            }
        }
        .font(LungfishInspectorStyle.controlFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("primerAnalysisInspector.files")
    }
}
