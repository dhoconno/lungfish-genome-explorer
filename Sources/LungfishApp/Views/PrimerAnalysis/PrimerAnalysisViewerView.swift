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

    var id: Self { self }
  }

  let bundleURL: URL
  let onLoadStateChanged: @MainActor (PrimerAnalysisViewerModel.State) -> Void
  let onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)?
  @StateObject private var model: PrimerAnalysisViewerModel
  @State private var selectedSection: Section
  @State private var retryGeneration: UInt64 = 0
  @State private var selection: PrimerReviewSelection?
  @State private var resultInspectionGeneration = 0

  init(bundleURL: URL, onLoadStateChanged: @escaping @MainActor (PrimerAnalysisViewerModel.State) -> Void = { _ in },
       onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)? = nil) {
    self.init(bundleURL: bundleURL, model: PrimerAnalysisViewerModel(), onLoadStateChanged: onLoadStateChanged,
      onExportRequested: onExportRequested)
  }

  init(
    bundleURL: URL,
    model: PrimerAnalysisViewerModel,
    selectedSection: Section = .overview,
    selection: PrimerReviewSelection? = nil,
    onLoadStateChanged: @escaping @MainActor (PrimerAnalysisViewerModel.State) -> Void = { _ in },
    onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)? = nil
  ) {
    self.bundleURL = bundleURL
    self.onLoadStateChanged = onLoadStateChanged
    self.onExportRequested = onExportRequested
    _model = StateObject(wrappedValue: model)
    _selectedSection = State(initialValue: selectedSection)
    _selection = State(initialValue: selection)
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
      guard !Task.isCancelled else { return }
      onLoadStateChanged(model.state)
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

      if selectedSection != .binding, let primerID = selection?.primerID,
        snapshot.bindingContexts.contains(where: { $0.primers.contains(where: { $0.reviewPrimerID == primerID }) }) {
        HStack {
          Text("Selected primer").font(.caption).foregroundStyle(.secondary)
          Button("Inspect in alignment") { selectedSection = .binding }
            .accessibilityIdentifier("primerAnalysisViewer.inspectSelectedBinding")
          Spacer()
        }.padding(.horizontal).padding(.bottom, 10)
      }
      Divider()
      if selectedSection == .binding {
        PrimerBindingInspectionView(contexts: snapshot.bindingContexts, selectedReviewPrimerID: selection?.primerID)
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
      ScrollViewReader { proxy in
      ScrollView {
        Group {
          switch selectedSection {
          case .overview: overview(snapshot)
          case .results:
            if let results = snapshot.primer3Results { Primer3ResultsView(results: results, bundleURL: snapshot.bundle.url, reviewTargets: snapshot.designReview, selection: $selection, onInspectSelection: { resultInspectionGeneration &+= 1 }) }
            else if !snapshot.primalSchemeResults.isEmpty { PrimalSchemeResultsView(results: snapshot.primalSchemeResults, engineDescription: snapshot.toolProvenance.first?.toolName ?? "PrimalScheme3", reviewTargets: snapshot.designReview, selection: $selection, onInspectSelection: { resultInspectionGeneration &+= 1 }) }
            else { Text("Native scheme outputs are preserved in the Inspector’s Files tab.").foregroundStyle(.secondary) }
          case .binding: EmptyView()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }
      .onChange(of: resultInspectionGeneration) {
        withAnimation { proxy.scrollTo(PrimerReviewSelection.selectedDesignAnchor, anchor: .top) }
      }
      }
      }
    }
    .environment(\.primerReviewActions, PrimerReviewContextActions(
      targets: snapshot.designReview,
      bindingPrimerIDs: Set(snapshot.bindingContexts.flatMap { $0.primers.map(\.reviewPrimerID) }),
      onInspectDetails: { if selectedSection == .results { resultInspectionGeneration &+= 1 } },
      onInspectBinding: { clicked in selection = clicked; selectedSection = .binding },
      onExportRequested: onExportRequested))
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
        ContentUnavailableView("Design summary unavailable", systemImage: "chart.bar.xaxis", description: Text("This saved analysis has no supported coordinates to summarize. Its original outputs remain available in the Inspector’s Files tab."))
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
          PrimerTargetReviewCard(target: target, selection: $selection)
        }
        Button("Inspect primers and pools") { selectedSection = .results }
          .accessibilityIdentifier("primerAnalysisViewer.inspectResults")
      }

    }
    .accessibilityIdentifier("primerAnalysisViewer.overview")
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
