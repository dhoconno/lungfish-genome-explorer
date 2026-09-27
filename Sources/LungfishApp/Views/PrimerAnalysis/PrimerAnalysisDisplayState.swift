import Foundation
import LungfishWorkflow
import Observation
import SwiftUI

private struct PrimerAnalysisVisibilityKey: EnvironmentKey {
  static let defaultValue = PrimerAnalysisVisibility()
}

extension EnvironmentValues {
  var primerAnalysisVisibility: PrimerAnalysisVisibility {
    get { self[PrimerAnalysisVisibilityKey.self] }
    set { self[PrimerAnalysisVisibilityKey.self] = newValue }
  }
}

/// Window-owned preferences hold no sequence data and do not modify scientific bundles.
@MainActor
final class PrimerAnalysisDisplayPreferences {
  var values: [String: PrimerAnalysisDisplaySettings] = [:]
}

@Observable @MainActor
final class PrimerAnalysisDisplaySession {
  var settings = PrimerAnalysisDisplaySettings() {
    didSet {
      if let preferenceKey { preferences?.values[preferenceKey] = settings }
    }
  }
  private(set) var targets: [PrimerTargetDesignReview]
  /// Primer3 candidate pairs, one review per pair. They never take part in scheme display filters.
  private(set) var primer3Candidates: [PrimerTargetDesignReview] = []
  /// Saved results that can become a `.lungfishprimers` scheme, with refusals explained.
  private(set) var schemeExportCandidates: [PrimerSchemeFromAnalysisCandidate] = []
  private(set) var compatibilitySummaries: [String: PrimerMSACompatibilitySummary] = [:]
  private(set) var isComputingCompatibility = false
  private(set) var compatibilityReady = false
  private(set) var compatibilityError: String?
  private var bindingContexts: [PrimerBindingInspectionContext]
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let preferences: PrimerAnalysisDisplayPreferences?
  @ObservationIgnored private var preferenceKey: String?
  @ObservationIgnored private var sourceSnapshot: PrimerAnalysisViewerSnapshot?
  var onOrderExportRequested: (@MainActor (PrimerOrderDraft, PrimerOrderMetadata) -> Void)?
  /// Saves one exportable result as a primer scheme named by the user.
  var onSchemeExportRequested: (@MainActor (PrimerSchemeFromAnalysisCandidate, String) -> Void)?

  init(targets: [PrimerTargetDesignReview] = [], bindingContexts: [PrimerBindingInspectionContext] = [],
       preferences: PrimerAnalysisDisplayPreferences? = nil) {
    self.targets = targets.filter { $0.presentation == .schemeReference }
    self.primer3Candidates = targets.filter { $0.presentation == .primer3Template && !$0.intervals.isEmpty }
    self.bindingContexts = bindingContexts
    self.preferences = preferences
  }

  /// Scheme results expose display filters; Primer3 results expose candidate ordering only.
  var isAvailable: Bool { !targets.isEmpty || hasPrimer3Candidates }
  var hasPrimer3Candidates: Bool { !primer3Candidates.isEmpty }
  var hasSchemeDisplayControls: Bool { !targets.isEmpty }

  /// Candidate pairs the user has not excluded from the next order. Hidden IDs are pair IDs.
  var includedPrimer3Candidates: [PrimerTargetDesignReview] {
    primer3Candidates.filter { !settings.hiddenPrimerIDs.contains($0.id) }
  }

  func setPrimer3CandidateIncluded(_ id: String, included: Bool) {
    if included { settings.hiddenPrimerIDs.remove(id) } else { settings.hiddenPrimerIDs.insert(id) }
  }

  var schemeExportUnavailableReason: String? {
    if sourceSnapshot == nil { return "Wait for a verified saved analysis." }
    if schemeExportCandidates.isEmpty {
      return hasPrimer3Candidates
        ? "Primer3 candidate pairs are alternatives, not a tiled scheme, so they cannot become a primer-trimming scheme."
        : "This analysis has no tiled scheme result to save."
    }
    if onSchemeExportRequested == nil { return "Open this analysis in its project to save a primer scheme." }
    if !schemeExportCandidates.contains(where: \.isExportable) {
      return schemeExportCandidates.first?.refusalReason
    }
    return nil
  }
  var hasBindingContexts: Bool { bindingContexts.contains { $0.unavailableReason == nil && !$0.primers.isEmpty } }
  var totalCount: Int { targets.reduce(0) { $0 + $1.primers.count } }
  var visibleCount: Int { targets.reduce(0) { $0 + visibility.visiblePrimers(in: $1).count } }
  var visibility: PrimerAnalysisVisibility {
    .init(settings: settings, summaries: compatibilitySummaries, compatibilityReady: compatibilityReady,
      isComputingCompatibility: isComputingCompatibility)
  }

  var orderExportUnavailableReason: String? {
    if !isAvailable || sourceSnapshot == nil { return "Wait for a verified saved analysis." }
    if onOrderExportRequested == nil { return "Open this analysis in its project to export an order." }
    if hasPrimer3Candidates {
      return includedPrimer3Candidates.isEmpty ? "Include at least one candidate pair to export an order." : nil
    }
    // Normalized scheme orders are explicit assay selections from saved records.
    // View filters only affect the viewport and must not redefine that membership.
    if sourceSnapshot?.primerSchemeResultsDocument != nil { return nil }
    if settings.filterByCompatibility && !compatibilityReady {
      return "Complete the MSA comparison before exporting the filtered order."
    }
    if visibleCount == 0 { return "Show at least one oligo to export an order." }
    return nil
  }

  var hasNormalizedSchemeResults: Bool { sourceSnapshot?.primerSchemeResultsDocument != nil }
  var analysisName: String { sourceSnapshot?.bundle.url.deletingPathExtension().lastPathComponent ?? "" }
  var hasReportedAlternatives: Bool {
    sourceSnapshot?.primerSchemeResultsDocument?.results.contains {
      $0.targets.contains { $0.assays.contains { $0.status == .alternative } }
    } == true
  }

  func makeOrderDraft(allReportedAssays: Bool = false) throws -> PrimerOrderDraft {
    if let reason = orderExportUnavailableReason { throw PrimerOrderExportError.invalid(reason) }
    guard let snapshot = sourceSnapshot else { throw PrimerOrderExportError.invalid("The saved analysis is unavailable.") }
    let assayIDs: [String]?
    let selectedPrimerIDs: [String]
    if hasPrimer3Candidates {
      // A Primer3 order names candidate pairs. Every oligo of an included pair is ordered.
      let included = includedPrimer3Candidates
      assayIDs = included.map(\.id)
      let roleOrder: [PrimerOligoRole: Int] = [.forward: 0, .probe: 1, .reverse: 2]
      selectedPrimerIDs = included.flatMap { candidate in
        candidate.primers.sorted { roleOrder[$0.role, default: 3] < roleOrder[$1.role, default: 3] }.map(\.id)
      }
    } else if let document = snapshot.primerSchemeResultsDocument {
      let assays = document.results.flatMap { $0.targets.flatMap(\.assays) }
        .filter { allReportedAssays || $0.status == .selected }
      assayIDs = assays.map { $0.id.uuidString.lowercased() }
      selectedPrimerIDs = try PrimerSchemeOrderSheet.rows(from: document,
        selection: .selectedAssays(Set(assays.map(\.id)))).map(\.id)
    } else {
      assayIDs = nil
      selectedPrimerIDs = targets.flatMap { visibility.visiblePrimers(in: $0).map(\.id) }
    }
    let selection = PrimerOrderSelection(capturedAt: Date(), analysisURL: snapshot.bundle.url,
      manifest: snapshot.bundle.manifest, settings: settings, compatibilityReady: compatibilityReady,
      compatibilitySummaries: compatibilityReady ? compatibilitySummaries : [:],
      selectedPrimerIDs: selectedPrimerIDs, selectedAssayIDs: assayIDs,
      includesAllReportedAssays: snapshot.primerSchemeResultsDocument == nil ? nil : allReportedAssays,
      primer3CandidatePairs: hasPrimer3Candidates ? true : nil)
    return PrimerOrderDraft(selection: selection,
      oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
      defaultName: snapshot.bundle.url.deletingPathExtension().lastPathComponent
        + (hasPrimer3Candidates ? " candidate pairs order" : allReportedAssays ? " all reported assays order" : " order"))
  }

  func isVisible(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> Bool {
    visibility.isVisible(primer, in: target)
  }

  func configure(_ snapshot: PrimerAnalysisViewerSnapshot) {
    cancel()
    sourceSnapshot = snapshot
    targets = snapshot.primer3Results == nil ? snapshot.designReview.filter { $0.presentation == .schemeReference } : []
    primer3Candidates = snapshot.primer3Results == nil ? []
      : snapshot.designReview.filter { $0.presentation == .primer3Template && !$0.intervals.isEmpty }
    schemeExportCandidates = snapshot.schemeExportCandidates
    bindingContexts = snapshot.inspectableBindingContexts
    compatibilitySummaries = [:]
    compatibilityReady = false
    compatibilityError = nil
    let manifest = snapshot.bundle.manifest
    let key = snapshot.bundle.url.standardizedFileURL.path + "::" + manifest.analysisID.uuidString + "::" + manifest.runID.uuidString
    preferenceKey = key
    settings = preferences?.values[key] ?? .init()
    if hasBindingContexts { computeCompatibility() }
  }

  func setPoolShown(_ pool: Int?, resultID: String, shown: Bool) {
    let id = PrimerAnalysisDisplaySettings.poolID(resultID: resultID, pool: pool)
    if shown { settings.hiddenPoolIDs.remove(id) } else { settings.hiddenPoolIDs.insert(id) }
  }

  func setPrimerShown(_ id: String, shown: Bool) {
    if shown { settings.hiddenPrimerIDs.remove(id) } else { settings.hiddenPrimerIDs.insert(id) }
  }

  func reset() { settings = .init() }

  func computeCompatibility() {
    guard hasBindingContexts, !isComputingCompatibility, !compatibilityReady else { return }
    isComputingCompatibility = true
    compatibilityError = nil
    let token = UUID()
    generation = token
    let contexts = bindingContexts
    work = Task { [weak self] in
      let worker = Task.detached(priority: .utility) { try PrimerMSACompatibilitySummary.compute(contexts: contexts) }
      do {
        let summaries = try await withTaskCancellationHandler(operation: { try await worker.value },
          onCancel: { worker.cancel() })
        guard let self, self.generation == token, !Task.isCancelled else { return }
        self.compatibilitySummaries = summaries
        self.compatibilityReady = true
        self.isComputingCompatibility = false
        self.work = nil
      } catch {
        guard let self, self.generation == token else { return }
        self.isComputingCompatibility = false
        if !(error is CancellationError) { self.compatibilityError = error.localizedDescription }
        self.work = nil
      }
    }
  }

  func cancel() {
    generation = UUID()
    work?.cancel()
    work = nil
    isComputingCompatibility = false
  }

  func invalidate() {
    cancel()
    sourceSnapshot = nil
    targets = []
    primer3Candidates = []
    schemeExportCandidates = []
    bindingContexts = []
    compatibilitySummaries = [:]
    compatibilityReady = false
    compatibilityError = nil
  }

  deinit { work?.cancel() }
}
