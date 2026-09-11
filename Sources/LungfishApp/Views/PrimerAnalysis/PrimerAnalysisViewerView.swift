import SwiftUI
import LungfishIO

struct PrimerAnalysisViewerView: View {
  private struct LoadIdentity: Hashable {
    let bundleURL: URL
    let retryGeneration: UInt64
  }

  enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case provenance = "Provenance"

    var id: Self { self }
  }

  let bundleURL: URL
  @StateObject private var model: PrimerAnalysisViewerModel
  @State private var selectedSection: Section
  @State private var retryGeneration: UInt64 = 0

  init(bundleURL: URL) {
    self.init(bundleURL: bundleURL, model: PrimerAnalysisViewerModel())
  }

  init(
    bundleURL: URL,
    model: PrimerAnalysisViewerModel,
    selectedSection: Section = .overview
  ) {
    self.bundleURL = bundleURL
    _model = StateObject(wrappedValue: model)
    _selectedSection = State(initialValue: selectedSection)
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        ProgressView("Loading saved primer analysis…")
          .accessibilityIdentifier("primerAnalysisViewer.loading")
      case .failed(let message):
        ContentUnavailableView {
          Label("Couldn’t Load Primer Analysis", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message).textSelection(.enabled)
        } actions: {
          Button("Retry") { retryGeneration &+= 1 }
            .accessibilityIdentifier("primerAnalysisViewer.retry")
        }
        .accessibilityIdentifier("primerAnalysisViewer.error")
      case .loaded(let snapshot):
        loadedContent(snapshot)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .task(id: LoadIdentity(bundleURL: bundleURL, retryGeneration: retryGeneration)) {
      await model.load(from: bundleURL)
    }
  }

  private func loadedContent(_ snapshot: PrimerAnalysisViewerSnapshot) -> some View {
    VStack(spacing: 0) {
      Picker("Saved result section", selection: $selectedSection) {
        ForEach(Section.allCases) { section in Text(section.rawValue).tag(section) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding()
      .accessibilityIdentifier("primerAnalysisViewer.tabs")

      Divider()
      ScrollView {
        Group {
          switch selectedSection {
          case .overview: overview(snapshot)
          case .files: files(snapshot)
          case .provenance: provenance(snapshot)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }
    }
  }

  private func overview(_ snapshot: PrimerAnalysisViewerSnapshot) -> some View {
    let manifest = snapshot.bundle.manifest
    return VStack(alignment: .leading, spacing: 18) {
      Text(snapshot.bundle.url.deletingPathExtension().lastPathComponent)
        .font(.title2.weight(.semibold))
        .textSelection(.enabled)
      field("Saved grouping", snapshot.groupingLabel)
      Text("\(manifest.inputs.count) input\(manifest.inputs.count == 1 ? "" : "s") • \(manifest.results.count) result\(manifest.results.count == 1 ? "" : "s")")
        .foregroundStyle(.secondary)

      DisclosureGroup("Saved identifiers") {
        VStack(alignment: .leading, spacing: 8) {
          field("Analysis ID", manifest.analysisID.uuidString)
          field("Run ID", manifest.runID.uuidString)
        }
        .padding(.top, 6)
      }

      sectionTitle("Inputs")
      ForEach(manifest.inputs, id: \.id) { input in
        record(label: input.label, id: input.id, lines: input.artifactPaths)
      }

      sectionTitle("Results")
      if manifest.results.isEmpty {
        Text("No result records are stored in this bundle.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(manifest.results, id: \.id) { result in
          resultRecord(result, inputs: manifest.inputs)
        }
      }
    }
    .accessibilityIdentifier("primerAnalysisViewer.overview")
  }

  private func files(_ snapshot: PrimerAnalysisViewerSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionTitle("Stored files")
      field("Current bundle location", snapshot.bundle.url.path)
      ForEach(
        snapshot.bundle.manifest.artifacts + [snapshot.bundle.manifest.provenance],
        id: \.relativePath
      ) { artifact in
        VStack(alignment: .leading, spacing: 4) {
          Text(artifact.relativePath).font(.headline).textSelection(.enabled)
          Text("Role: \(artifact.role) • Format: \(artifact.format)")
          Text("Size: \(artifact.byteSize) bytes")
          Text("SHA-256: \(artifact.sha256)").font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
      }
    }
    .accessibilityIdentifier("primerAnalysisViewer.files")
  }

  private func provenance(_ snapshot: PrimerAnalysisViewerSnapshot) -> some View {
    let provenance = snapshot.provenance
    return VStack(alignment: .leading, spacing: 16) {
      sectionTitle("Wrapper provenance")
      field("Workflow", "\(provenance.workflowName) \(provenance.workflowVersion)")
      field("Tool", "\(provenance.toolName) \(provenance.toolVersion)")
      field("Command", provenance.reproducibleCommand)
      field("Exit status", provenance.exitStatus.map(String.init) ?? "Not recorded")
      field(
        "Wall time", provenance.wallTimeSeconds.map { String(format: "%.3f seconds", $0) }
          ?? "Not recorded")
      field("Published bundle location", snapshot.bundle.manifest.publishedRootPath)
      field("Current bundle location", snapshot.bundle.url.path)
      sectionTitle("Original canonical JSON")
      Text(snapshot.provenanceJSON)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
    .accessibilityIdentifier("primerAnalysisViewer.provenance")
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.title3.weight(.semibold))
  }

  private func field(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  private func record(label: String?, id: UUID, lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label ?? "Unlabeled record").font(.headline)
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(line).font(.caption).textSelection(.enabled)
      }
      DisclosureGroup("Stable identifier") {
        Text(id.uuidString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      }
    }
  }

  private func resultRecord(
    _ result: PrimerAnalysisResult,
    inputs: [PrimerAnalysisInput]
  ) -> some View {
    let labelsByID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.label) })
    let membershipLabels = result.inputIDs.map { id in
      (labelsByID[id] ?? nil) ?? "Unlabeled input"
    }
    return VStack(alignment: .leading, spacing: 4) {
      Text(result.label ?? "Unlabeled record").font(.headline)
      Text("Input memberships: \(membershipLabels.joined(separator: ", "))")
        .font(.caption)
      ForEach(result.artifactPaths, id: \.self) { path in
        Text("Artifact: \(path)").font(.caption).textSelection(.enabled)
      }
      DisclosureGroup("Stable identifiers") {
        VStack(alignment: .leading, spacing: 3) {
          Text("Result: \(result.id.uuidString)")
          ForEach(result.inputIDs, id: \.self) { id in
            Text("Input: \(id.uuidString)")
          }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
      }
    }
  }
}
