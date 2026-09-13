import Foundation

public enum PrimerAnalysisGrouping: String, Codable, Sendable {
  case independent
  case combined
}

public struct PrimerAnalysisInput: Codable, Sendable, Equatable {
  public let id: UUID
  public let label: String?
  public let artifactPaths: [String]

  public init(id: UUID, label: String? = nil, artifactPaths: [String]) {
    self.id = id
    self.label = label
    self.artifactPaths = artifactPaths
  }
}

public struct PrimerAnalysisResult: Codable, Sendable, Equatable {
  public let id: UUID
  public let label: String?
  public let inputIDs: [UUID]
  public let artifactPaths: [String]

  public init(id: UUID, label: String? = nil, inputIDs: [UUID], artifactPaths: [String]) {
    self.id = id
    self.label = label
    self.inputIDs = inputIDs
    self.artifactPaths = artifactPaths
  }
}

public struct PrimerAnalysisArtifact: Codable, Sendable, Equatable {
  public let relativePath: String
  public let role: String
  public let format: String
  public let sha256: String
  public let byteSize: UInt64

  public init(relativePath: String, role: String, format: String, sha256: String, byteSize: UInt64)
  {
    self.relativePath = relativePath
    self.role = role
    self.format = format
    self.sha256 = sha256
    self.byteSize = byteSize
  }
}

public struct PrimerAnalysisManifest: Codable, Sendable, Equatable {
  public static let filename = "manifest.json"
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let analysisID: UUID
  public let runID: UUID
  public let inputs: [PrimerAnalysisInput]
  public let results: [PrimerAnalysisResult]
  public let artifacts: [PrimerAnalysisArtifact]
  public let provenance: PrimerAnalysisArtifact
  public let grouping: PrimerAnalysisGrouping
  public let publishedRootPath: String

  public init(
    schemaVersion: Int = Self.currentSchemaVersion, analysisID: UUID, runID: UUID,
    inputs: [PrimerAnalysisInput], results: [PrimerAnalysisResult],
    artifacts: [PrimerAnalysisArtifact], provenance: PrimerAnalysisArtifact,
    grouping: PrimerAnalysisGrouping, publishedRootPath: String
  ) {
    self.schemaVersion = schemaVersion
    self.analysisID = analysisID
    self.runID = runID
    self.inputs = inputs
    self.results = results
    self.artifacts = artifacts
    self.provenance = provenance
    self.grouping = grouping
    self.publishedRootPath = publishedRootPath
  }
}
