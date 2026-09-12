import AppKit
import SwiftUI
import LungfishIO

struct PrimerAnalysisViewerView: View {
  private struct LoadIdentity: Hashable {
    let bundleURL: URL
    let retryGeneration: UInt64
  }

  enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case results = "Results"
    case binding = "Binding inspection"
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
      if selectedSection == .binding {
        PrimerBindingInspectionView(contexts: snapshot.bindingContexts)
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
      ScrollView {
        Group {
          switch selectedSection {
          case .overview: overview(snapshot)
          case .results:
            if let results = snapshot.primer3Results { Primer3ResultsView(results: results, bundleURL: snapshot.bundle.url) }
            else if !snapshot.primalSchemeResults.isEmpty { PrimalSchemeResultsView(results: snapshot.primalSchemeResults, engineDescription: snapshot.toolProvenance.first?.toolName ?? "PrimalScheme3") }
            else { Text("Native scheme outputs are preserved in the Files inventory.").foregroundStyle(.secondary) }
          case .binding: EmptyView()
          case .files: files(snapshot)
          case .provenance: provenance(snapshot)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }
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

      if snapshot.designReview.isEmpty {
        ContentUnavailableView("Design summary unavailable", systemImage: "chart.bar.xaxis", description: Text("This saved analysis has no supported coordinates to summarize. Its original outputs remain available in Files."))
      } else {
        HStack(spacing: 28) {
          summaryMetric(snapshot.primer3Results == nil ? "Mapping references" : "Candidate reviews", value: String(snapshot.designReview.count))
          summaryMetric("Primer sites", value: String(snapshot.designReview.reduce(0) { $0 + $1.primers.count }))
          if snapshot.primer3Results == nil {
            summaryMetric("Scheme pools", value: String(snapshot.primalSchemeResults.reduce(0) { $0 + Set($1.primers.map(\.pool)).count }))
          }
        }
        Text(snapshot.primer3Results == nil
          ? "Coverage shows the span of saved amplicons across each mapping reference. It does not measure amplification success or the fraction of alleles that will amplify."
          : "Review each candidate pair separately. Template span is the portion between that pair’s outer primer boundaries; alternative pairs are not combined into a scheme.")
          .font(.callout).foregroundStyle(.secondary)
        ForEach(snapshot.designReview) { target in
          PrimerTargetReviewCard(target: target)
        }
        Button("Inspect primers and pools") { selectedSection = .results }
          .accessibilityIdentifier("primerAnalysisViewer.inspectResults")
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
          HStack {
            Text(artifact.relativePath).font(.headline).textSelection(.enabled)
            Spacer()
            Button("Show in Finder") {
              if let url = try? snapshot.bundle.artifactURL(forRelativePath: artifact.relativePath) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
              }
            }.controlSize(.small)
          }
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
      ForEach(Array(snapshot.toolProvenance.enumerated()), id: \.offset) { index, execution in
        sectionTitle("Tool execution \(index + 1)")
        field("Tool", "\(execution.toolName) \(execution.toolVersion)")
        field("Executed argv", execution.argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " "))
        field("Recorded command", execution.reproducibleCommand)
        field("Exit status", execution.exitStatus.map(String.init) ?? "Not recorded")
        field("Wall time", execution.wallTimeSeconds.map { String(format: "%.3f seconds", $0) } ?? "Not recorded")
        field("Runtime", execution.runtimeIdentity.executablePath)
        if let environment = execution.runtimeIdentity.condaEnvironment { field("Conda environment", environment) }
        if let stderr = execution.stderr, !stderr.isEmpty {
          DisclosureGroup("Tool stderr") { Text(stderr).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }
        Divider()
      }
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

  private func summaryMetric(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value).font(.title2.weight(.semibold)).monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}
