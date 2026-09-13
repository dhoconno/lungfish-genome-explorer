import Foundation
import LungfishIO
import LungfishWorkflow

/// A frozen selection of saved oligos. Display controls never rerun or optimize the design.
struct PrimerOrderSelection: Codable, Equatable, Sendable {
  let capturedAt: Date
  let analysisURL: URL
  let manifest: PrimerAnalysisManifest
  let settings: PrimerAnalysisDisplaySettings
  let compatibilityReady: Bool
  let compatibilitySummaries: [String: PrimerMSACompatibilitySummary]
  let selectedPrimerIDs: [String]
}

struct PrimerOrderMetadata: Codable, Equatable, Sendable {
  var name: String = "Primer order"
  var requestedBy: String = ""
  var project: String = ""
  var orderReference: String = ""
  var notes: String = ""
}

struct PrimerOrderOligo: Codable, Equatable, Identifiable, Sendable {
  var id: String { primerID }
  let primerID: String
  let targetID: String
  let sourceResultID: String
  let schemeLabel: String
  /// Unique within this order; independent schemes with the same pool number stay separate.
  let poolName: String
  let pool: Int
  let referenceID: String
  let name: String
  let sequence: String
  let start: Int
  let end: Int
  let strand: String
  let ampliconIDs: [String]
  let compatibility: PrimerMSACompatibilitySummary?
}

struct PrimerOrderDraft: Identifiable, Sendable {
  let id = UUID()
  let selection: PrimerOrderSelection
  let oligos: [PrimerOrderOligo]
  let defaultName: String
  var sourceName: String { selection.analysisURL.deletingPathExtension().lastPathComponent }
}

struct PrimerOrderDocument: Codable, Sendable {
  static let filename = "order.json"
  static let toolID = "primer-order"
  let schemaVersion: Int
  let metadata: PrimerOrderMetadata
  let selection: PrimerOrderSelection
  let oligos: [PrimerOrderOligo]
  let outputDirectoryPath: String
  let templateSHA256: String
  let sequenceSemantics: String
}

/// The viewport and Inspector share the exact provenance envelope verified during loading.
struct PrimerOrderViewerSnapshot: Sendable {
  let document: PrimerOrderDocument
  let provenance: ProvenanceEnvelope
}
