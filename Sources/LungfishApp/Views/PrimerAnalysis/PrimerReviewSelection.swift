import Foundation

/// Shared navigation state for Overview and Results; scientific membership comes from saved review records.
struct PrimerReviewSelection: Equatable, Sendable {
  static let selectedDesignAnchor = "primerAnalysisViewer.selectedDesign"

  let targetID: String
  var primerID: String?
  var ampliconID: String?
}

extension PrimerReviewSelection {
  static func selecting(primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> Self {
    let matches = target.intervals.filter { primer.ampliconIDs.contains($0.id) && $0.primerIDs.contains(primer.id) }
    return .init(targetID: target.id, primerID: primer.id, ampliconID: matches.count == 1 ? matches[0].id : nil)
  }
}
