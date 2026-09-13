import Foundation
import Observation
import SwiftUI

/// Rendering preferences. An explicit order export may capture these with the displayed IDs;
/// they never change native design parameters or the saved design.
struct PrimerAnalysisDisplaySettings: Codable, Equatable, Sendable {
  var hiddenPrimerIDs: Set<String> = []
  var hiddenPoolIDs: Set<String> = []
  var showForward = true
  var showReverse = true
  var showAmplicons = true
  var showIdentityDots = true
  var filterByCompatibility = false
  var minimumCompatibilityPercent: Double = 0
  var showUnassessed = true

  static func poolID(resultID: String, pool: Int?) -> String {
    resultID + "::pool::" + (pool.map(String.init) ?? "none")
  }
}

/// A positional comparison of one saved oligo, not native discovery frequency or assay coverage.
struct PrimerMSACompatibilitySummary: Codable, Equatable, Sendable {
  let matchingRows: Int
  let assessableRows: Int
  let totalRows: Int
  var unknownRows: Int { totalRows - assessableRows }
  var percent: Double? { assessableRows > 0 ? 100 * Double(matchingRows) / Double(assessableRows) : nil }
  var label: String {
    let fraction = percent.map { String(format: "%.1f%%", $0) } ?? "unavailable"
    return "MSA matches: \(fraction) (\(matchingRows)/\(assessableRows))"
  }
  var help: String {
    "\(matchingRows) matching sequences out of \(assessableRows) that can be compared at this primer site. The MSA contains \(totalRows) sequences, including the reference row; \(unknownRows) cannot be assessed because the site has gaps, unknown bases, or cannot be mapped. Matching means no incompatible bases across the primer, accounting for its strand and allowed primer bases. This sequence comparison does not measure amplification."
  }

  nonisolated static func compute(contexts: [PrimerBindingInspectionContext]) throws -> [String: Self] {
    var summaries: [String: Self] = [:]
    for context in contexts where context.unavailableReason == nil {
      for primer in context.primers {
        try Task.checkCancellation()
        guard !primer.reviewPrimerID.isEmpty, summaries[primer.reviewPrimerID] == nil else {
          throw NSError(domain: "PrimerDisplay", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Saved primer-to-alignment correspondence is ambiguous."])
        }
        // Retain counts only; release each primer's row comparisons before processing the next.
        let rows = try context.comparisons(for: primer)
        summaries[primer.reviewPrimerID] = .init(matchingRows: rows.filter { $0.mismatchCount == 0 }.count,
          assessableRows: rows.filter { $0.mismatchCount != nil }.count, totalRows: rows.count)
      }
    }
    return summaries
  }
}

struct PrimerAnalysisVisibility: Sendable {
  var settings = PrimerAnalysisDisplaySettings()
  var summaries: [String: PrimerMSACompatibilitySummary] = [:]
  var compatibilityReady = false
  var isComputingCompatibility = false

  func isPoolVisible(_ pool: Int?, resultID: String) -> Bool {
    !settings.hiddenPoolIDs.contains(PrimerAnalysisDisplaySettings.poolID(resultID: resultID, pool: pool))
  }

  func isVisible(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> Bool {
    guard target.presentation == .schemeReference else { return true }
    guard !settings.hiddenPrimerIDs.contains(primer.id), isPoolVisible(primer.pool, resultID: target.sourceResultID),
      primer.strand != "+" || settings.showForward, primer.strand != "-" || settings.showReverse else { return false }
    guard settings.filterByCompatibility, compatibilityReady else { return true }
    guard let percent = summaries[primer.id]?.percent else { return settings.showUnassessed }
    return percent >= min(100, max(0, settings.minimumCompatibilityPercent))
  }

  func visiblePrimers(in target: PrimerTargetDesignReview) -> [PrimerReviewPrimer] {
    target.primers.filter { isVisible($0, in: target) }
  }

  func bindingPrimerIDs(in contexts: [PrimerBindingInspectionContext], targets: [PrimerTargetDesignReview]) -> Set<String> {
    let displayed = Set(targets.flatMap { visiblePrimers(in: $0).map(\.id) })
    return Set(contexts.flatMap { $0.primers.map(\.reviewPrimerID) }).intersection(displayed)
  }

  func filtering(_ context: PrimerBindingInspectionContext, targets: [PrimerTargetDesignReview]) -> PrimerBindingInspectionContext {
    let visibleIDs = Set(targets.flatMap { visiblePrimers(in: $0).map(\.id) })
    let primers = context.primers.filter { visibleIDs.contains($0.reviewPrimerID) }
    let annotationIDs = Set(primers.map(\.id))
    return .init(id: context.id, title: context.title, alignedFASTA: context.alignedFASTA,
      annotations: context.annotations.filter { annotationIDs.contains($0.id) }, primers: primers,
      unavailableReason: context.unavailableReason, rows: context.rows)
  }
}

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

  init(targets: [PrimerTargetDesignReview] = [], bindingContexts: [PrimerBindingInspectionContext] = [],
       preferences: PrimerAnalysisDisplayPreferences? = nil) {
    self.targets = targets.filter { $0.presentation == .schemeReference }
    self.bindingContexts = bindingContexts
    self.preferences = preferences
  }

  var isAvailable: Bool { !targets.isEmpty }
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
    if settings.filterByCompatibility && !compatibilityReady {
      return "Complete the MSA comparison before exporting the filtered order."
    }
    if visibleCount == 0 { return "Show at least one oligo to export an order." }
    return nil
  }

  func makeOrderDraft() throws -> PrimerOrderDraft {
    if let reason = orderExportUnavailableReason { throw PrimerOrderExportError.invalid(reason) }
    guard let snapshot = sourceSnapshot else { throw PrimerOrderExportError.invalid("The saved analysis is unavailable.") }
    let selection = PrimerOrderSelection(capturedAt: Date(), analysisURL: snapshot.bundle.url,
      manifest: snapshot.bundle.manifest, settings: settings, compatibilityReady: compatibilityReady,
      compatibilitySummaries: compatibilityReady ? compatibilitySummaries : [:],
      selectedPrimerIDs: targets.flatMap { visibility.visiblePrimers(in: $0).map(\.id) })
    return PrimerOrderDraft(selection: selection,
      oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
      defaultName: snapshot.bundle.url.deletingPathExtension().lastPathComponent + " order")
  }

  func isVisible(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> Bool {
    visibility.isVisible(primer, in: target)
  }

  func configure(_ snapshot: PrimerAnalysisViewerSnapshot) {
    cancel()
    sourceSnapshot = snapshot
    targets = snapshot.primer3Results == nil ? snapshot.designReview.filter { $0.presentation == .schemeReference } : []
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
    bindingContexts = []
    compatibilitySummaries = [:]
    compatibilityReady = false
    compatibilityError = nil
  }

  deinit { work?.cancel() }
}
