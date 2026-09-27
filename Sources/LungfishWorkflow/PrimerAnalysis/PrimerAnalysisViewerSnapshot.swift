import CryptoKit
import Foundation
import LungfishIO

public enum PrimerAnalysisViewerSection: String, CaseIterable, Identifiable, Sendable {
  case overview = "Overview"
  case results = "Results"
  case binding = "Binding inspection"
  public var id: Self { self }
}

public struct PrimerAnalysisViewerSnapshot: Sendable {
  public let bundle: PrimerAnalysisBundle
  public let provenance: ProvenanceEnvelope
  public let provenanceJSON: String
  public let primer3Results: Primer3NormalizedResults?
  public let toolProvenance: [ProvenanceEnvelope]
  public let primalSchemeResults: [PrimalSchemeDisplayResult]
  public var primerSchemeResultsDocument: PrimerSchemeResultsDocument? = nil
  public var derivedProvenance: [ProvenanceEnvelope] = []
  public var workflowProvenance: [ProvenanceEnvelope] = []
  public var designReview: [PrimerTargetDesignReview] = []
  public var bindingContexts: [PrimerBindingInspectionContext] = []
  /// Saved results that can become a `.lungfishprimers` scheme, with refusals explained.
  public var schemeExportCandidates: [PrimerSchemeFromAnalysisCandidate] = []

  public init(
    bundle: PrimerAnalysisBundle,
    provenance: ProvenanceEnvelope,
    provenanceJSON: String,
    primer3Results: Primer3NormalizedResults?,
    toolProvenance: [ProvenanceEnvelope],
    primalSchemeResults: [PrimalSchemeDisplayResult],
    primerSchemeResultsDocument: PrimerSchemeResultsDocument? = nil,
    derivedProvenance: [ProvenanceEnvelope] = [],
    workflowProvenance: [ProvenanceEnvelope] = [],
    designReview: [PrimerTargetDesignReview] = [],
    bindingContexts: [PrimerBindingInspectionContext] = [],
    schemeExportCandidates: [PrimerSchemeFromAnalysisCandidate] = []
  ) {
    self.bundle = bundle
    self.provenance = provenance
    self.provenanceJSON = provenanceJSON
    self.primer3Results = primer3Results
    self.toolProvenance = toolProvenance
    self.primalSchemeResults = primalSchemeResults
    self.primerSchemeResultsDocument = primerSchemeResultsDocument
    self.derivedProvenance = derivedProvenance
    self.workflowProvenance = workflowProvenance
    self.designReview = designReview
    self.bindingContexts = bindingContexts
    self.schemeExportCandidates = schemeExportCandidates
  }

  public var inspectableBindingContexts: [PrimerBindingInspectionContext] {
    bindingContexts.filter { $0.unavailableReason == nil && !$0.rows.isEmpty && !$0.primers.isEmpty }
  }

  public var supportsBindingInspection: Bool { !inspectableBindingContexts.isEmpty }

  /// Primer3 results always offer the section. Single-sequence templates have no alignment
  /// to compare against, so the section then explains that instead of hiding.
  public var availableSections: [PrimerAnalysisViewerSection] {
    [.overview, .results] + (supportsBindingInspection || primer3Results != nil ? [.binding] : [])
  }

  public var bindingUnavailableExplanation: String? {
    guard primer3Results != nil, !supportsBindingInspection else { return nil }
    return "These Primer3 candidates were designed on a single template sequence, so there is no alignment to compare their binding sites against. Design from an alignment bundle and choose a template row to see every row's bases under each primer."
  }

  public func visibleSection(_ requested: PrimerAnalysisViewerSection) -> PrimerAnalysisViewerSection {
    availableSections.contains(requested) ? requested : .overview
  }

  public nonisolated static func load(from url: URL) throws -> Self {
    let bundle = try PrimerAnalysisBundle.load(from: url) {
      try Task.checkCancellation()
    }
    let provenance = try ProvenanceEnvelopeReader.decodeCanonical(
      bundle.canonicalProvenanceData)
    guard let provenanceJSON = String(data: bundle.canonicalProvenanceData, encoding: .utf8) else {
      throw PrimerAnalysisBundleError.invalidProvenance("canonical provenance is not UTF-8")
    }
    let normalizedPath = "results/primer3-normalized-v1.json"
    let normalized: Primer3NormalizedResults?
    if let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == normalizedPath }) {
      let decoded = try JSONDecoder().decode(Primer3NormalizedResults.self, from: verifiedBytes(artifact, in: bundle))
      try validateNormalizedResults(decoded, in: bundle)
      normalized = decoded
    } else { normalized = nil }
    let schemePath = PrimerSchemeResultsDocument.storedRelativePath
    let schemeDocument: PrimerSchemeResultsDocument?
    var schemeProjections: [String: PrimerBindingProjection] = [:]
    if let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == schemePath }) {
      guard normalized == nil else {
        throw PrimerAnalysisBundleError.invalidArtifact(
          "A primer analysis cannot contain both Primer3 and normalized scheme payloads.")
      }
      let document = try JSONDecoder().decode(
        PrimerSchemeResultsDocument.self, from: verifiedBytes(artifact, in: bundle))
      guard document.analysisID == bundle.manifest.analysisID,
            document.runID == bundle.manifest.runID else {
        throw PrimerAnalysisBundleError.invalidArtifact(
          "Normalized primer-scheme analysis or run identity disagrees with the bundle.")
      }
      let expectedResults = Set(bundle.manifest.results.filter {
        $0.artifactPaths.contains(schemePath)
      }.map(\.id))
      guard Set(document.results.map(\.id)) == expectedResults else {
        throw PrimerAnalysisBundleError.invalidArtifact(
          "Normalized primer-scheme results disagree with bundle membership.")
      }
      for path in Set(document.results.flatMap {
        $0.targets.map(\.bindingProjectionPath)
      }) {
        guard let mapArtifact = bundle.manifest.artifacts.first(where: { $0.relativePath == path }) else {
          throw PrimerAnalysisBundleError.invalidArtifact(
            "A normalized primer-scheme binding projection is missing.")
        }
        schemeProjections[path] = try JSONDecoder().decode(
          PrimerBindingProjection.self, from: verifiedBytes(mapArtifact, in: bundle))
      }
      try document.validateStored(
        knownInputIDs: Set(bundle.manifest.inputs.map(\.id)), projections: schemeProjections)
      schemeDocument = document
    } else { schemeDocument = nil }
    let toolProvenance = try bundle.manifest.artifacts.filter { $0.role == "toolProvenance" }.map {
      try ProvenanceEnvelopeReader.decodeCanonical(verifiedBytes($0, in: bundle))
    }
    let derivedProvenance = try bundle.manifest.artifacts.filter { $0.role == "derivedProvenance" }.map {
      try ProvenanceEnvelopeReader.decodeCanonical(verifiedBytes($0, in: bundle))
    }
    let workflowProvenance = try bundle.manifest.artifacts.filter { $0.role == "workflowProvenance" }.map {
      try ProvenanceEnvelopeReader.decodeCanonical(verifiedBytes($0, in: bundle))
    }
    struct RowMap: Decodable {
      struct Row: Decodable { let rowIndex: Int; let originalHeader: String; let normalizedHeader: String }
      let schemaVersion: Int
      let inputID: UUID
      let rows: [Row]
    }
    var labels: [String: String] = [:]
    for input in bundle.manifest.inputs {
      let path = "inputs/\(input.id.uuidString)-row-map.json"
      guard input.artifactPaths.contains(path),
        let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == path }) else { continue }
      let mapping = try JSONDecoder().decode(RowMap.self, from: verifiedBytes(artifact, in: bundle))
      guard mapping.schemaVersion == 1, mapping.inputID == input.id, !mapping.rows.isEmpty else {
        throw PrimerAnalysisBundleError.invalidArtifact("Invalid PrimalScheme row-map identity")
      }
      for (index, row) in mapping.rows.enumerated() {
        let expected = "input_\(input.id.uuidString.replacingOccurrences(of: "-", with: ""))_row_\(index)"
        guard row.rowIndex == index, row.normalizedHeader == expected,
          !row.originalHeader.isEmpty, labels[expected] == nil else {
          throw PrimerAnalysisBundleError.invalidArtifact("Invalid PrimalScheme row-map membership")
        }
        labels[expected] = row.originalHeader
      }
    }
    var schemes: [PrimalSchemeDisplayResult] = []
    var reviews: [PrimerTargetDesignReview] = normalized.map(PrimerDesignReview.primer3) ?? []
    for result in bundle.manifest.results {
      for path in result.artifactPaths where path.hasSuffix("/primer.bed") {
        let referencePath = String(path.dropLast("primer.bed".count)) + "reference.fasta"
        guard result.artifactPaths.contains(referencePath),
          let bed = bundle.manifest.artifacts.first(where: { $0.relativePath == path }),
          let reference = bundle.manifest.artifacts.first(where: { $0.relativePath == referencePath }) else { continue }
        let orderPath = String(path.dropLast("primer.bed".count)) + PrimalSchemeOrderSheet.filename
        var orderSheetURL: URL?
        if result.artifactPaths.contains(orderPath),
          let orderArtifact = bundle.manifest.artifacts.first(where: { $0.relativePath == orderPath }) {
          let storedOrder = try verifiedBytes(orderArtifact, in: bundle)
          guard storedOrder == (try PrimalSchemeOrderSheet.csv(fromBED: verifiedBytes(bed, in: bundle))) else {
            throw PrimerAnalysisBundleError.invalidArtifact("Ordering worksheet does not agree with the stored primer records")
          }
          orderSheetURL = try bundle.artifactURL(forRelativePath: orderPath)
        }
        schemes.append(try PrimalSchemeDisplayResult.parse(id: path,
          title: result.label ?? result.id.uuidString,
          bed: verifiedBytes(bed, in: bundle), reference: verifiedBytes(reference, in: bundle), referenceLabels: labels, orderSheetURL: orderSheetURL))
        let ampliconPath = String(path.dropLast("primer.bed".count)) + "amplicon.bed"
        let ampliconArtifact = result.artifactPaths.contains(ampliconPath)
          ? bundle.manifest.artifacts.first(where: { $0.relativePath == ampliconPath }) : nil
        reviews += try PrimerDesignReview.primalScheme(id: path, label: result.label ?? result.id.uuidString,
          reference: verifiedBytes(reference, in: bundle),
          amplicons: ampliconArtifact.map { try verifiedBytes($0, in: bundle) },
          primers: schemes.last!.primers, labels: labels)

      }
    }
    let legacySchemes = schemes
    var normalizedBindingContexts: [PrimerBindingInspectionContext] = []
    if let schemeDocument {
      let presentation = try PrimerSchemeViewerAdapter.adapt(document: schemeDocument)
      schemes += presentation.results
      reviews += presentation.reviews
      normalizedBindingContexts = try PrimerBindingInspectionContext.loadNormalized(
        bundle: bundle, document: schemeDocument, projections: schemeProjections)
    }
    let primer3BindingContexts = try normalized.map {
      try PrimerBindingInspectionContext.loadPrimer3(bundle: bundle, results: $0)
    } ?? []
    let schemeCandidates = normalized == nil
      ? (try? PrimerSchemeFromAnalysisService.candidates(analysisURL: bundle.url)) ?? [] : []
    return Self(bundle: bundle, provenance: provenance, provenanceJSON: provenanceJSON,
                primer3Results: normalized, toolProvenance: toolProvenance, primalSchemeResults: schemes,
                primerSchemeResultsDocument: schemeDocument,
                derivedProvenance: derivedProvenance, workflowProvenance: workflowProvenance,
                designReview: reviews,
                bindingContexts: try PrimerBindingInspectionContext.load(
                  bundle: bundle, schemes: legacySchemes) + normalizedBindingContexts + primer3BindingContexts,
                schemeExportCandidates: schemeCandidates)
  }

  private nonisolated static func verifiedBytes(_ artifact: PrimerAnalysisArtifact, in bundle: PrimerAnalysisBundle) throws -> Data {
    try Task.checkCancellation()
    let data = try Data(contentsOf: bundle.artifactURL(forRelativePath: artifact.relativePath))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard UInt64(data.count) == artifact.byteSize, digest == artifact.sha256.lowercased() else {
      throw PrimerAnalysisBundleError.integrityMismatch(artifact.relativePath)
    }
    return data
  }

  private nonisolated static func validateNormalizedResults(_ normalized: Primer3NormalizedResults, in bundle: PrimerAnalysisBundle) throws {
    func invalid(_ reason: String) -> PrimerAnalysisBundleError { .invalidArtifact("Primer3 normalized results: " + reason) }
    guard normalized.schemaVersion == Primer3NormalizedResults.schemaVersion,
      normalized.analysisID == bundle.manifest.analysisID, normalized.runID == bundle.manifest.runID else {
      throw invalid("unsupported schema or mismatched analysis identity")
    }
    let expectedIDs = Set(bundle.manifest.results.filter {
      $0.artifactPaths.contains("results/primer3-normalized-v1.json")
    }.map(\.id))
    guard Set(normalized.results.map(\.resultID)) == expectedIDs else {
      throw invalid("normalized results do not cover the stored result memberships")
    }
    var resultIDs: Set<UUID> = []
    var objectIDs: Set<UUID> = []
    for result in normalized.results {
      try Task.checkCancellation()
      guard resultIDs.insert(result.resultID).inserted,
        let membership = bundle.manifest.results.first(where: { $0.id == result.resultID }),
        membership.inputIDs.contains(result.inputID), result.sourceIndex >= 0 else {
        throw invalid("invalid result membership")
      }
      let length = result.templateSequence.utf8.count
      guard length > 0, result.templateSequence.utf8.allSatisfy({ $0 < 128 }) else {
        throw invalid("invalid template sequence")
      }
      for range in result.excludedRegions {
        guard range.start >= 0, range.end > range.start, range.end <= length else { throw invalid("invalid excluded region") }
      }
      for pair in result.pairs {
        guard objectIDs.insert(pair.id).inserted, pair.productSize > 0,
          pair.left.orientation == .forward, pair.right.orientation == .reverse,
          pair.productSize == pair.right.end - pair.left.start else { throw invalid("invalid primer pair") }
        for oligo in [pair.left, pair.right] + (pair.internalOligo.map { [$0] } ?? []) {
          guard objectIDs.insert(oligo.id).inserted, oligo.start >= 0, oligo.end > oligo.start,
            oligo.end <= length, oligo.sequence.utf8.count == oligo.end - oligo.start,
            oligo.meltingTemperature.isFinite, oligo.gcPercent.isFinite,
            (0...100).contains(oligo.gcPercent) else { throw invalid("invalid oligo coordinates or properties") }
        }
      }
    }
  }

  public var groupingLabel: String {
    if primer3Results != nil { return "Independent primer design per selected template" }
    if let primerSchemeResultsDocument {
      if primerSchemeResultsDocument.engine == .varvamp {
        return "Independent varVAMP \(primerSchemeResultsDocument.mode.rawValue) design per input"
      }
      return bundle.manifest.grouping == .combined
        ? "Combined Olivar tiled scheme" : "One Olivar tiled scheme per input"
    }
    switch bundle.manifest.grouping {
    case .independent: return "One scheme per alignment"
    case .combined: return "Combined scheme"
    }
  }
}
