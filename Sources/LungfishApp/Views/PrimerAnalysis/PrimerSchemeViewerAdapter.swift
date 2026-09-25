import Foundation
import LungfishWorkflow

struct PrimerSchemeViewerPresentation: Sendable {
  let results: [PrimalSchemeDisplayResult]
  let reviews: [PrimerTargetDesignReview]
}

enum PrimerSchemeViewerAdapter {
  enum SourceProjection: Equatable, Sendable {
    case exact(start: Int, end: Int)
    case unavailable(String)
  }

  static func adapt(document: PrimerSchemeResultsDocument) throws -> PrimerSchemeViewerPresentation {
    var displayResults: [PrimalSchemeDisplayResult] = []
    var reviews: [PrimerTargetDesignReview] = []
    for result in document.results {
      try Task.checkCancellation()
      let resultID = result.id.uuidString.lowercased()
      var displayPrimers: [PrimalSchemeDisplayPrimer] = []
      var nextGroup = 1
      var poolGroups: [String: Int] = [:]
      var assayGroups: [UUID: Int] = [:]
      for target in result.targets {
        for assay in target.assays {
          let group: Int
          if let pool = assay.pool {
            if let existing = poolGroups[pool] { group = existing }
            else { group = nextGroup; poolGroups[pool] = group; nextGroup += 1 }
          } else {
            group = nextGroup; nextGroup += 1
          }
          assayGroups[assay.id] = group
        }
        let assayByID = Dictionary(uniqueKeysWithValues: target.assays.map { ($0.id, $0) })
        for oligo in target.oligos {
          guard let firstAssayID = oligo.assayIDs.first,
                let assay = assayByID[firstAssayID],
                let displayGroup = assayGroups[firstAssayID] else {
            throw PrimerSchemeDesignError.contractViolation(
              "A normalized viewer oligo has no verified assay membership.")
          }
          displayPrimers.append(.init(id: displayPrimers.count,
            stableID: oligo.id.uuidString.lowercased(), reference: target.referenceID,
            referenceLabel: target.label, start: oligo.start, end: oligo.end,
            name: oligo.name, pool: displayGroup, nativePool: oligo.pool ?? assay.pool,
            displayGroupLabel: (oligo.pool ?? assay.pool).map { "Pool \($0)" }
              ?? (assay.status == .selected ? "Unpooled · selected assay"
                : "Unpooled · alternative" + (assay.rank.map { " rank \($0)" } ?? "")),
            strand: oligo.strand.rawValue, sequence: oligo.sequence,
            referenceLength: target.referenceLength, role: oligo.role,
            assayIDs: oligo.assayIDs.map { $0.uuidString.lowercased() },
            candidateStatus: assay.status, candidateRank: assay.rank))
        }

        let reviewIntervals = target.assays.enumerated().map { index, assay in
          let groupLabel = assay.pool.map { "Pool \($0)" }
            ?? (assay.status == .selected ? "Unpooled · selected assay"
              : "Unpooled · alternative" + (assay.rank.map { " rank \($0)" } ?? ""))
          return PrimerReviewInterval(id: assay.id.uuidString.lowercased(),
            start: assay.start, end: assay.end, pool: assayGroups[assay.id],
            nativePool: assay.pool,
            poolLabel: groupLabel,
            candidateStatus: assay.status, rank: assay.rank,
            name: assay.status == .selected ? "Selected assay"
              : "Alternative assay \(assay.rank ?? (index + 1))",
            primerIDs: assay.memberIDs.map { $0.uuidString.lowercased() })
        }
        let reviewPrimers = target.oligos.map { oligo -> PrimerReviewPrimer in
          let assay = oligo.assayIDs.compactMap { assayByID[$0] }.first!
          let groupLabel = (oligo.pool ?? assay.pool).map { "Pool \($0)" }
            ?? (assay.status == .selected ? "Unpooled · selected assay"
              : "Unpooled · alternative" + (assay.rank.map { " rank \($0)" } ?? ""))
          return .init(id: oligo.id.uuidString.lowercased(), name: oligo.name,
            start: oligo.start, end: oligo.end, strand: oligo.strand.rawValue,
            pool: assayGroups[assay.id],
            poolLabel: groupLabel,
            role: oligo.role, candidateStatus: assay.status, rank: assay.rank,
            nativePool: oligo.pool ?? assay.pool,
            sequence: oligo.sequence,
            ampliconIDs: oligo.assayIDs.map { $0.uuidString.lowercased() })
        }
        reviews.append(.init(id: target.id.uuidString.lowercased(), label: target.label,
          referenceLength: target.referenceLength,
          coverageLabel: document.mode == .tiled
            ? "Generated reference spanned by tiled assays"
            : "Descriptive union of reported assay spans",
          coveredBases: PrimerDesignReview.coveredBases(reviewIntervals), intervals: reviewIntervals,
          primers: reviewPrimers,
          notes: [
            "Coordinates are zero-based half-open on the saved generated reference; displayed spans include primer sites.",
            "Candidate status, oligo role and native pool identity come from the validated normalized result.",
            document.mode == .tiled
              ? "Overlapping tiled assay spans count once."
              : "Reported alternatives are separate candidates; their displayed span union is not one compatible panel.",
            "Unpooled assays remain unpooled. Display grouping does not create scientific pool membership.",
          ], advisories: document.varVAMPCoverageAdvisories(for: target),
          sourceResultID: resultID, referenceID: target.referenceID))
      }
      let engine = document.engine == .olivar ? "Olivar" : "varVAMP"
      displayResults.append(.init(id: resultID,
        title: "\(engine) · \(resultID.prefix(8))", primers: displayPrimers, orderSheetURL: nil))
    }
    return .init(results: displayResults, reviews: reviews)
  }

  static func project(
    oligo: PrimerSchemeOligo, through projection: PrimerBindingProjection
  ) -> SourceProjection {
    let overlapping = projection.blocks.filter { block in
      if block.generatedStart == block.generatedEnd {
        return oligo.start < block.generatedStart && oligo.end > block.generatedStart
      }
      return block.generatedStart < oligo.end && block.generatedEnd > oligo.start
    }
    guard !overlapping.isEmpty else {
      return .unavailable("No saved projection block covers this oligo.")
    }
    if let nonMapped = overlapping.first(where: { $0.kind != .mapped }) {
      return .unavailable(
        nonMapped.kind == .collapsed
          ? "The oligo crosses a collapsed source interval; original-row mismatch statistics are unavailable."
          : "The oligo crosses a synthetic reference interval; original-row mismatch statistics are unavailable.")
    }
    var projectedStart: Int?
    var projectedEnd: Int?
    var expectedSourceStart: Int?
    for block in overlapping {
      guard let sourceStart = block.sourceStart, let sourceEnd = block.sourceEnd else {
        return .unavailable("The saved projection has no source coordinates.")
      }
      let clippedStart = max(oligo.start, block.generatedStart)
      let clippedEnd = min(oligo.end, block.generatedEnd)
      let start = sourceStart + clippedStart - block.generatedStart
      let end = sourceEnd - (block.generatedEnd - clippedEnd)
      if let expectedSourceStart, start != expectedSourceStart {
        return .unavailable(
          "The oligo has a discontinuous source projection; original-row mismatch statistics are unavailable.")
      }
      projectedStart = projectedStart ?? start
      projectedEnd = end
      expectedSourceStart = end
    }
    guard let start = projectedStart, let end = projectedEnd,
          end - start == oligo.end - oligo.start else {
      return .unavailable(
        "The oligo projection is not one-to-one; original-row mismatch statistics are unavailable.")
    }
    return .exact(start: start, end: end)
  }
}
