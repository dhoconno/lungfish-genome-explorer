import Foundation
import LungfishIO

/// A frozen selection of saved oligos. Display controls never rerun or optimize the design.
public struct PrimerOrderSelection: Codable, Equatable, Sendable {
  public let capturedAt: Date
  public let analysisURL: URL
  public let manifest: PrimerAnalysisManifest
  public let settings: PrimerAnalysisDisplaySettings
  public let compatibilityReady: Bool
  public let compatibilitySummaries: [String: PrimerMSACompatibilitySummary]
  public let selectedPrimerIDs: [String]
  public var selectedAssayIDs: [String]? = nil
  public var includesAllReportedAssays: Bool? = nil
  /// Set when `selectedAssayIDs` names Primer3 candidate pairs rather than saved scheme assays.
  public var primer3CandidatePairs: Bool? = nil

  public init(
    capturedAt: Date,
    analysisURL: URL,
    manifest: PrimerAnalysisManifest,
    settings: PrimerAnalysisDisplaySettings,
    compatibilityReady: Bool,
    compatibilitySummaries: [String: PrimerMSACompatibilitySummary],
    selectedPrimerIDs: [String],
    selectedAssayIDs: [String]? = nil,
    includesAllReportedAssays: Bool? = nil,
    primer3CandidatePairs: Bool? = nil
  ) {
    self.capturedAt = capturedAt
    self.analysisURL = analysisURL
    self.manifest = manifest
    self.settings = settings
    self.compatibilityReady = compatibilityReady
    self.compatibilitySummaries = compatibilitySummaries
    self.selectedPrimerIDs = selectedPrimerIDs
    self.selectedAssayIDs = selectedAssayIDs
    self.includesAllReportedAssays = includesAllReportedAssays
    self.primer3CandidatePairs = primer3CandidatePairs
  }

  public var isPrimer3CandidateSelection: Bool { primer3CandidatePairs == true }
}

/// Which saved oligos an order captures. Each scope applies to one kind of saved analysis.
public enum PrimerOrderScope: Sendable, Equatable {
  /// Every oligo of the named Primer3 candidate pairs; each pair is an independent alternative.
  case primer3CandidatePairs(includedPairIDs: [String])
  /// The selected assays of a normalized Olivar or varVAMP result.
  case selectedAssays
  /// Every reported assay, selected and alternative, of a normalized Olivar or varVAMP result.
  case allReportedAssays
  /// The oligos a PrimalScheme result displays under the captured view settings.
  case displayed
}

public struct PrimerOrderMetadata: Codable, Equatable, Sendable {
  public var name: String = "Primer order"
  public var requestedBy: String = ""
  public var project: String = ""
  public var orderReference: String = ""
  public var notes: String = ""

  public init(
    name: String = "Primer order",
    requestedBy: String = "",
    project: String = "",
    orderReference: String = "",
    notes: String = ""
  ) {
    self.name = name
    self.requestedBy = requestedBy
    self.project = project
    self.orderReference = orderReference
    self.notes = notes
  }
}

public struct PrimerOrderOligo: Codable, Equatable, Identifiable, Sendable {
  public var id: String { primerID }
  public let primerID: String
  public let targetID: String
  public let sourceResultID: String
  public let schemeLabel: String
  /// Unique within this order; independent schemes with the same pool number stay separate.
  public let poolName: String
  public let pool: Int?
  public let referenceID: String
  public let name: String
  public let sequence: String
  public let start: Int
  public let end: Int
  public let strand: String
  public let ampliconIDs: [String]
  public let compatibility: PrimerMSACompatibilitySummary?
  public var sourceOligoID: String? = nil
  public var oligoRole: PrimerOligoRole? = nil
  public var candidateStatus: PrimerAssayStatus? = nil
  public var assayIDs: [String]? = nil
  public var nativePool: String? = nil

  public init(
    primerID: String,
    targetID: String,
    sourceResultID: String,
    schemeLabel: String,
    poolName: String,
    pool: Int?,
    referenceID: String,
    name: String,
    sequence: String,
    start: Int,
    end: Int,
    strand: String,
    ampliconIDs: [String],
    compatibility: PrimerMSACompatibilitySummary?,
    sourceOligoID: String? = nil,
    oligoRole: PrimerOligoRole? = nil,
    candidateStatus: PrimerAssayStatus? = nil,
    assayIDs: [String]? = nil,
    nativePool: String? = nil
  ) {
    self.primerID = primerID
    self.targetID = targetID
    self.sourceResultID = sourceResultID
    self.schemeLabel = schemeLabel
    self.poolName = poolName
    self.pool = pool
    self.referenceID = referenceID
    self.name = name
    self.sequence = sequence
    self.start = start
    self.end = end
    self.strand = strand
    self.ampliconIDs = ampliconIDs
    self.compatibility = compatibility
    self.sourceOligoID = sourceOligoID
    self.oligoRole = oligoRole
    self.candidateStatus = candidateStatus
    self.assayIDs = assayIDs
    self.nativePool = nativePool
  }
}

public struct PrimerOrderDraft: Identifiable, Sendable {
  public let id = UUID()
  public let selection: PrimerOrderSelection
  public let oligos: [PrimerOrderOligo]
  public let defaultName: String

  public init(
    selection: PrimerOrderSelection,
    oligos: [PrimerOrderOligo],
    defaultName: String
  ) {
    self.selection = selection
    self.oligos = oligos
    self.defaultName = defaultName
  }
  public var sourceName: String { selection.analysisURL.deletingPathExtension().lastPathComponent }
}

public struct PrimerOrderDocument: Codable, Sendable {
  public static let filename = "order.json"
  public static let toolID = "primer-order"
  public let schemaVersion: Int
  public let metadata: PrimerOrderMetadata
  public let selection: PrimerOrderSelection
  public let oligos: [PrimerOrderOligo]
  public let outputDirectoryPath: String
  public let templateSHA256: String
  public let sequenceSemantics: String

  public init(
    schemaVersion: Int,
    metadata: PrimerOrderMetadata,
    selection: PrimerOrderSelection,
    oligos: [PrimerOrderOligo],
    outputDirectoryPath: String,
    templateSHA256: String,
    sequenceSemantics: String
  ) {
    self.schemaVersion = schemaVersion
    self.metadata = metadata
    self.selection = selection
    self.oligos = oligos
    self.outputDirectoryPath = outputDirectoryPath
    self.templateSHA256 = templateSHA256
    self.sequenceSemantics = sequenceSemantics
  }
}

/// The viewport and Inspector share the exact provenance envelope verified during loading.
public struct PrimerOrderViewerSnapshot: Sendable {
  public let document: PrimerOrderDocument
  public let provenance: ProvenanceEnvelope

  public init(
    document: PrimerOrderDocument,
    provenance: ProvenanceEnvelope
  ) {
    self.document = document
    self.provenance = provenance
  }
}
