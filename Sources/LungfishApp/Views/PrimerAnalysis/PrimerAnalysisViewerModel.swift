import Combine
import CryptoKit
import Foundation
import LungfishIO
import LungfishWorkflow

struct PrimerAnalysisViewerSnapshot: Sendable {
  let bundle: PrimerAnalysisBundle
  let provenance: ProvenanceEnvelope
  let provenanceJSON: String
  let primer3Results: Primer3NormalizedResults?
  let toolProvenance: [ProvenanceEnvelope]
  let primalSchemeResults: [PrimalSchemeDisplayResult]
  var derivedProvenance: [ProvenanceEnvelope] = []
  var workflowProvenance: [ProvenanceEnvelope] = []
  var designReview: [PrimerTargetDesignReview] = []
  var bindingContexts: [PrimerBindingInspectionContext] = []

  nonisolated static func load(from url: URL) throws -> Self {
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
    return Self(bundle: bundle, provenance: provenance, provenanceJSON: provenanceJSON,
                primer3Results: normalized, toolProvenance: toolProvenance, primalSchemeResults: schemes,
                derivedProvenance: derivedProvenance, workflowProvenance: workflowProvenance,
                designReview: reviews, bindingContexts: try PrimerBindingInspectionContext.load(bundle: bundle, schemes: schemes))
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

  var groupingLabel: String {
    if primer3Results != nil { return "Independent primer design per selected template" }
    switch bundle.manifest.grouping {
    case .independent: return "One scheme per alignment"
    case .combined: return "Combined scheme"
    }
  }
}

@MainActor
final class PrimerAnalysisViewerModel: ObservableObject {
  enum State {
    case loading
    case loaded(PrimerAnalysisViewerSnapshot)
    case failed(String)
  }

  @Published private(set) var state: State = .loading

  private let loader: @Sendable (URL) async throws -> PrimerAnalysisViewerSnapshot
  private var loadGeneration: UInt64 = 0

  init(
    loader: @escaping @Sendable (URL) async throws -> PrimerAnalysisViewerSnapshot = {
      try PrimerAnalysisViewerSnapshot.load(from: $0)
    }
  ) {
    self.loader = loader
  }

  func load(from url: URL) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    state = .loading
    let loader = self.loader
    let worker = Task.detached(priority: .userInitiated) {
      try await loader(url)
    }
    do {
      let snapshot = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard generation == loadGeneration, !Task.isCancelled else { return }
      state = .loaded(snapshot)
    } catch {
      guard generation == loadGeneration, !Task.isCancelled else { return }
      state = .failed(error.localizedDescription)
    }
  }
}
