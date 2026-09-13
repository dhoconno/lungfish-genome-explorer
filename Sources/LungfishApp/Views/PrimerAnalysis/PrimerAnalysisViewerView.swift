import AppKit
import SwiftUI
import LungfishIO

struct PrimerAnalysisViewerView: View {
  private struct LoadIdentity: Hashable {
    let bundleURL: URL
    let retryGeneration: UInt64
  }

  typealias Section = PrimerAnalysisViewerSection

  let bundleURL: URL
  let onLoadStateChanged: @MainActor (PrimerAnalysisViewerModel.State) -> Void
  let onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)?
  @StateObject private var model: PrimerAnalysisViewerModel
  @State private var displaySession: PrimerAnalysisDisplaySession
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
    displaySession: PrimerAnalysisDisplaySession? = nil,
    onLoadStateChanged: @escaping @MainActor (PrimerAnalysisViewerModel.State) -> Void = { _ in },
    onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)? = nil
  ) {
    self.bundleURL = bundleURL
    self.onLoadStateChanged = onLoadStateChanged
    self.onExportRequested = onExportRequested
    _model = StateObject(wrappedValue: model)
    _selectedSection = State(initialValue: selectedSection)
    _selection = State(initialValue: selection)
    _displaySession = State(initialValue: displaySession ?? PrimerAnalysisDisplaySession())
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
      if case .loaded(let snapshot) = model.state { displaySession.configure(snapshot) }
      onLoadStateChanged(model.state)
    }
    .onDisappear { displaySession.cancel() }
  }

  private func loadedContent(_ snapshot: PrimerAnalysisViewerSnapshot) -> some View {
    let visibleSection = snapshot.visibleSection(selectedSection)
    let bindingContexts = snapshot.inspectableBindingContexts
    let bindingPrimerIDs = displaySession.visibility.bindingPrimerIDs(in: bindingContexts, targets: snapshot.designReview)
    return VStack(spacing: 0) {
      Picker("Saved result section", selection: Binding(
        get: { visibleSection }, set: { selectedSection = snapshot.visibleSection($0) })) {
        ForEach(snapshot.availableSections) { section in Text(section.rawValue).tag(section) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding()
      .accessibilityIdentifier("primerAnalysisViewer.tabs")

      if snapshot.primer3Results == nil, displaySession.isAvailable {
        Text("\(displaySession.visibleCount)/\(displaySession.totalCount) oligos shown")
          .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal).padding(.bottom, 8)
          .help("Adjust visibility in Inspector → View. Saved coverage and full-set exports remain based on the complete saved scheme.")
          .accessibilityIdentifier("primerAnalysisViewer.displaySummary")
      }

      if visibleSection != .binding, let primerID = selection?.primerID,
        bindingPrimerIDs.contains(primerID) {
        HStack {
          Text("Selected primer").font(.caption).foregroundStyle(.secondary)
          Button("Inspect in alignment") { selectedSection = .binding }
            .accessibilityIdentifier("primerAnalysisViewer.inspectSelectedBinding")
          Spacer()
        }.padding(.horizontal).padding(.bottom, 10)
      }
      Divider()
      if visibleSection == .binding {
        PrimerBindingInspectionView(contexts: bindingContexts, selectedReviewPrimerID: selection?.primerID,
          visibility: displaySession.visibility, reviewTargets: snapshot.designReview,
          identityDots: Binding(get: { displaySession.settings.showIdentityDots }, set: { displaySession.settings.showIdentityDots = $0 }))
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
      ScrollViewReader { proxy in
      ScrollView {
        Group {
          switch visibleSection {
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
    .onChange(of: snapshot.availableSections, initial: true) { _, _ in
      selectedSection = snapshot.visibleSection(selectedSection)
    }
    .onChange(of: displaySession.settings) { _, _ in reconcileVisibleSelection(snapshot) }
    .onChange(of: displaySession.compatibilityReady) { _, _ in reconcileVisibleSelection(snapshot) }
    .environment(\.primerAnalysisVisibility, displaySession.visibility)
    .environment(\.primerReviewActions, PrimerReviewContextActions(
      targets: snapshot.designReview,
      bindingPrimerIDs: bindingPrimerIDs,
      onInspectDetails: { if selectedSection == .results { resultInspectionGeneration &+= 1 } },
      onInspectBinding: { clicked in
        guard let primerID = clicked.primerID, bindingPrimerIDs.contains(primerID) else { return }
        selection = clicked; selectedSection = .binding
      },
      onExportRequested: onExportRequested))
  }

  private func reconcileVisibleSelection(_ snapshot: PrimerAnalysisViewerSnapshot) {
    guard let current = selection, let id = current.primerID,
      let target = snapshot.designReview.first(where: { $0.id == current.targetID }),
      let primer = target.primers.first(where: { $0.id == id }),
      !displaySession.isVisible(primer, in: target) else { return }
    // Keep the amplicon context; hiding a primer never silently selects a different oligo.
    selection = .init(targetID: current.targetID, primerID: nil, ampliconID: current.ampliconID)
  }

  private func overview(_ snapshot: PrimerAnalysisViewerSnapshot) -> some View {
    return VStack(alignment: .leading, spacing: 18) {
      if snapshot.designReview.isEmpty {
        ContentUnavailableView("Design summary unavailable", systemImage: "chart.bar.xaxis", description: Text("This saved analysis has no supported coordinates to summarize. Its original outputs remain available in the Inspector’s Files tab."))
      } else {
        ForEach(snapshot.designReview) { target in
          PrimerTargetReviewCard(target: target, selection: $selection)
        }
        Button(snapshot.primer3Results == nil ? "Inspect primers and pools" : "Inspect candidate details") { selectedSection = .results }
          .accessibilityIdentifier("primerAnalysisViewer.inspectResults")
      }

    }
    .accessibilityIdentifier("primerAnalysisViewer.overview")
  }

}
