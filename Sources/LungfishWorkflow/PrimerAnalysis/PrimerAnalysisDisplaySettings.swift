import Foundation

/// Rendering preferences. An explicit order export may capture these with the displayed IDs;
/// they never change native design parameters or the saved design.
public struct PrimerAnalysisDisplaySettings: Codable, Equatable, Sendable {
  public var hiddenPrimerIDs: Set<String> = []
  public var hiddenPoolIDs: Set<String> = []
  public var showForward = true
  public var showReverse = true
  public var showAmplicons = true
  public var showIdentityDots = true
  public var filterByCompatibility = false
  public var minimumCompatibilityPercent: Double = 0
  public var showUnassessed = true

  public init(
    hiddenPrimerIDs: Set<String> = [], hiddenPoolIDs: Set<String> = [], showForward: Bool = true,
    showReverse: Bool = true, showAmplicons: Bool = true, showIdentityDots: Bool = true,
    filterByCompatibility: Bool = false, minimumCompatibilityPercent: Double = 0, showUnassessed: Bool = true
  ) {
    self.hiddenPrimerIDs = hiddenPrimerIDs; self.hiddenPoolIDs = hiddenPoolIDs
    self.showForward = showForward; self.showReverse = showReverse; self.showAmplicons = showAmplicons
    self.showIdentityDots = showIdentityDots; self.filterByCompatibility = filterByCompatibility
    self.minimumCompatibilityPercent = minimumCompatibilityPercent; self.showUnassessed = showUnassessed
  }

  public static func poolID(resultID: String, pool: Int?) -> String {
    resultID + "::pool::" + (pool.map(String.init) ?? "none")
  }
}

/// A positional comparison of one saved oligo, not native discovery frequency or assay coverage.
public struct PrimerMSACompatibilitySummary: Codable, Equatable, Sendable {
  public let matchingRows: Int
  public let assessableRows: Int
  public let totalRows: Int

  public init(matchingRows: Int, assessableRows: Int, totalRows: Int) {
    self.matchingRows = matchingRows; self.assessableRows = assessableRows; self.totalRows = totalRows
  }
  public var unknownRows: Int { totalRows - assessableRows }
  public var percent: Double? { assessableRows > 0 ? 100 * Double(matchingRows) / Double(assessableRows) : nil }
  public var label: String {
    let fraction = percent.map { String(format: "%.1f%%", $0) } ?? "unavailable"
    return "MSA matches: \(fraction) (\(matchingRows)/\(assessableRows))"
  }
  public var help: String {
    "\(matchingRows) matching sequences out of \(assessableRows) that can be compared at this primer site. The MSA contains \(totalRows) sequences, including the reference row; \(unknownRows) cannot be assessed because the site has gaps, unknown bases, or cannot be mapped. Matching means no incompatible bases across the primer, accounting for its strand and allowed primer bases. This sequence comparison does not measure amplification."
  }

  public nonisolated static func compute(contexts: [PrimerBindingInspectionContext]) throws -> [String: Self] {
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

public struct PrimerAnalysisVisibility: Sendable {
  public var settings = PrimerAnalysisDisplaySettings()
  public var summaries: [String: PrimerMSACompatibilitySummary] = [:]
  public var compatibilityReady = false
  public var isComputingCompatibility = false

  public init(
    settings: PrimerAnalysisDisplaySettings = .init(), summaries: [String: PrimerMSACompatibilitySummary] = [:],
    compatibilityReady: Bool = false, isComputingCompatibility: Bool = false
  ) {
    self.settings = settings; self.summaries = summaries
    self.compatibilityReady = compatibilityReady; self.isComputingCompatibility = isComputingCompatibility
  }

  public func isPoolVisible(_ pool: Int?, resultID: String) -> Bool {
    !settings.hiddenPoolIDs.contains(PrimerAnalysisDisplaySettings.poolID(resultID: resultID, pool: pool))
  }

  public func isVisible(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> Bool {
    guard target.presentation == .schemeReference else { return true }
    guard !settings.hiddenPrimerIDs.contains(primer.id), isPoolVisible(primer.pool, resultID: target.sourceResultID),
      primer.strand != "+" || settings.showForward, primer.strand != "-" || settings.showReverse else { return false }
    guard settings.filterByCompatibility, compatibilityReady else { return true }
    guard let percent = summaries[primer.id]?.percent else { return settings.showUnassessed }
    return percent >= min(100, max(0, settings.minimumCompatibilityPercent))
  }

  public func visiblePrimers(in target: PrimerTargetDesignReview) -> [PrimerReviewPrimer] {
    target.primers.filter { isVisible($0, in: target) }
  }

  public func bindingPrimerIDs(in contexts: [PrimerBindingInspectionContext], targets: [PrimerTargetDesignReview]) -> Set<String> {
    let displayed = Set(targets.flatMap { visiblePrimers(in: $0).map(\.id) })
    return Set(contexts.flatMap { $0.primers.map(\.reviewPrimerID) }).intersection(displayed)
  }

  public func filtering(_ context: PrimerBindingInspectionContext, targets: [PrimerTargetDesignReview]) -> PrimerBindingInspectionContext {
    let visibleIDs = Set(targets.flatMap { visiblePrimers(in: $0).map(\.id) })
    let primers = context.primers.filter { visibleIDs.contains($0.reviewPrimerID) }
    let annotationIDs = Set(primers.map(\.id))
    return .init(id: context.id, title: context.title, alignedFASTA: context.alignedFASTA,
      annotations: context.annotations.filter { annotationIDs.contains($0.id) }, primers: primers,
      unavailableReason: context.unavailableReason, rows: context.rows)
  }
}
