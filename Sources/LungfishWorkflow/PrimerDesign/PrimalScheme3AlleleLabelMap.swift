import Foundation
import LungfishIO

public struct PrimalScheme3AlleleLabelMap: Codable, Equatable, Sendable {
  public static let schemaVersion = "lungfish.primer-analysis.allele-label-map/v1"

  public struct Row: Codable, Equatable, Sendable {
    public let sourceMSAIndex: Int
    public let inputID: UUID
    public let rowIndex: Int
    public let nativeRowID: String
    public let displayLabel: String
    public let nativeFASTARecordID: String
    public let nativeFASTADescription: String
    public let normalizedHeader: String
    public let originalHeader: String
    public let lgeRowName: String?
    public let originalName: String?
    public let stableLGERowID: String?
    public let sourceSequenceName: String?
  }

  public struct AlleleClass: Codable, Equatable, Sendable {
    public let targetID: String
    public let alleleID: String
    public let multiplicity: Int
    public let rows: [Row]
  }

  public let schemaVersion: String
  public let resultID: UUID
  public let nativeSchemaVersion: String
  public let nativeLabelMapRelativePath: String
  public let scope: String
  public let classes: [AlleleClass]
}

enum PrimalScheme3AlleleLabelBridge {
  struct Input: Sendable {
    let id: UUID
    let rowMappingURL: URL
    let sourceMetadataURL: URL?
  }

  struct Publication: Sendable {
    let artifacts: [PrimerAnalysisSourceArtifact]
    let resultArtifactPaths: [String]
  }

  private static let nativeSchema = "primalscheme3.allele-label-map/v1"

  static func publishIfAdvertised(
    nativeOutputURL: URL,
    inputs: [Input],
    resultID: UUID,
    scratchRootURL: URL,
    publishedRootURL: URL,
    invocation: PrimerAnalysisWrapperInvocation,
    auditValidation: Data?,
    auditValidationURL: URL?
  ) throws -> Publication? {
    let startedAt = Date()
    let optimizerURL = nativeOutputURL.appendingPathComponent("panel-optimizer.json")
    let optimizer = try decode(NativeOptimizer.self, from: optimizerURL)
    guard let reference = optimizer.publication?.alleleLabelMap else { return nil }
    guard reference.schemaVersion == nativeSchema else {
      throw invalid("The advertised native allele label map schema is unsupported.")
    }
    let nativeMapURL = try contained(nativeOutputURL, relativePath: reference.path)
    let nativeMap = try decode(NativeMap.self, from: nativeMapURL)
    guard nativeMap.schemaVersion == nativeSchema,
      nativeMap.scientificIdentityRole == "display-only-excluded"
    else {
      throw invalid("The advertised native allele label map identity is invalid.")
    }
    try validateAudit(auditValidation, reference: reference, map: nativeMap)
    let derived = try derive(
      nativeMap: nativeMap, nativeMapRelativePath: reference.path,
      nativeOutputURL: nativeOutputURL, inputs: inputs,
      resultID: resultID)

    let mapPath = "derived/\(resultID.uuidString)/allele-label-map.json"
    let mapURL = scratchRootURL.appendingPathComponent(mapPath)
    try FileManager.default.createDirectory(
      at: mapURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(derived).write(to: mapURL, options: .withoutOverwriting)

    let nativeMapPath = try relative(nativeMapURL, to: scratchRootURL)
    var builder = ProvenanceRunBuilder(
      workflowName: "lungfish.primalscheme3.allele-label-enrichment", workflowVersion: "1",
      toolName: "Lungfish Allele Label Enrichment", toolVersion: invocation.callerVersion
    )
    .argv(invocation.argv)
    .options(
      explicit: ["schemaVersion": .string(PrimalScheme3AlleleLabelMap.schemaVersion)],
      defaults: [:],
      resolved: [
        "resultID": .string(resultID.uuidString),
        "nativeSchemaVersion": .string(nativeSchema),
        "nativeLabelMapRelativePath": .string(nativeMapPath),
        "inputIDs": .array(inputs.map { .string($0.id.uuidString) }),
        "scope": .string("Display labels only; scientific IDs and coverage are unchanged."),
        "argvMeaning": .string(
          "Exact host-process invocation; this deterministic stored-artifact join is replayed from the recorded input files."
        ),
      ]
    )
    .runtime(invocation.runtimeIdentity)
    builder = try builder.consumedInputSnapshot(
      try descriptor(
        source: nativeMapURL,
        published: publishedRootURL.appendingPathComponent(nativeMapPath), role: .input))
    let optimizerPath = try relative(optimizerURL, to: scratchRootURL)
    builder = try builder.consumedInputSnapshot(
      try descriptor(
        source: optimizerURL,
        published: publishedRootURL.appendingPathComponent(optimizerPath), role: .input))
    guard let auditValidationURL else {
      throw invalid("The advertised native allele label map has no retained audit evidence.")
    }
    guard let auditValidation,
      try Data(contentsOf: auditValidationURL) == auditValidation
    else {
      throw invalid("The retained allele label audit evidence differs from the validated receipt.")
    }
    let auditPath = try relative(auditValidationURL, to: scratchRootURL)
    builder = try builder.consumedInputSnapshot(
      try descriptor(
        source: auditValidationURL,
        published: publishedRootURL.appendingPathComponent(auditPath), role: .input))
    for input in nativeMap.inputs {
      let stored = try contained(nativeOutputURL, relativePath: input.storedPath)
      let storedPath = try relative(stored, to: scratchRootURL)
      builder = try builder.consumedInputSnapshot(
        try descriptor(
          source: stored,
          published: publishedRootURL.appendingPathComponent(storedPath),
          role: .input, format: .fasta))
    }
    for input in inputs {
      let rowMapPath = try relative(input.rowMappingURL, to: scratchRootURL)
      builder = try builder.consumedInputSnapshot(
        try descriptor(
          source: input.rowMappingURL,
          published: publishedRootURL.appendingPathComponent(rowMapPath), role: .input))
      if let metadataURL = input.sourceMetadataURL {
        let metadataPath = try relative(metadataURL, to: scratchRootURL)
        builder = try builder.consumedInputSnapshot(
          try descriptor(
            source: metadataURL,
            published: publishedRootURL.appendingPathComponent(metadataPath), role: .input))
      }
    }
    builder = try builder.relocatedOutput(
      try descriptor(
        source: mapURL, published: publishedRootURL.appendingPathComponent(mapPath), role: .output))
    let envelope = try builder.complete(
      exitStatus: 0, stderr: "", startedAt: startedAt, endedAt: Date())
    let provenancePath = "logs/\(resultID.uuidString)/allele-label-map.json"
    let provenanceURL = scratchRootURL.appendingPathComponent(provenancePath)
    try FileManager.default.createDirectory(
      at: provenanceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let provenanceEncoder = JSONEncoder()
    provenanceEncoder.dateEncodingStrategy = .iso8601
    provenanceEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try provenanceEncoder.encode(envelope).write(to: provenanceURL, options: .withoutOverwriting)
    let artifacts = [
      PrimerAnalysisSourceArtifact(
        sourceURL: mapURL, relativePath: mapPath, role: "derived-label-map", format: "json"),
      PrimerAnalysisSourceArtifact(
        sourceURL: provenanceURL, relativePath: provenancePath,
        role: "derivedProvenance", format: "json"),
    ]
    return .init(artifacts: artifacts, resultArtifactPaths: artifacts.map(\.relativePath))
  }

  private static func derive(
    nativeMap: NativeMap,
    nativeMapRelativePath: String,
    nativeOutputURL: URL,
    inputs: [Input],
    resultID: UUID
  ) throws -> PrimalScheme3AlleleLabelMap {
    guard !inputs.isEmpty,
      nativeMap.inputs.map(\.sourceMSAIndex) == Array(inputs.indices),
      nativeMap.targets.map(\.sourceMSAIndex) == Array(inputs.indices),
      Set(nativeMap.targets.map(\.targetID)).count == nativeMap.targets.count
    else {
      throw invalid("Native allele label source occurrences do not match the result inputs.")
    }
    for descriptor in nativeMap.inputs {
      let stored = try contained(nativeOutputURL, relativePath: descriptor.storedPath)
      guard try ProvenanceFileHasher.sha256(of: stored) == descriptor.sha256,
        try ProvenanceFileHasher.fileSize(of: stored) == descriptor.size
      else {
        throw invalid("A saved native label input does not match its hash and size.")
      }
    }

    var classes: [PrimalScheme3AlleleLabelMap.AlleleClass] = []
    var classIDs = Set<String>()
    var allNativeRowIDs = Set<String>()
    for target in nativeMap.targets {
      let input = inputs[target.sourceMSAIndex]
      let rowMap = try decode(RowMap.self, from: input.rowMappingURL)
      guard rowMap.schemaVersion == 1, rowMap.inputID == input.id,
        rowMap.rows.map(\.rowIndex) == Array(target.rows.indices),
        target.rows.map(\.rowIndex) == Array(target.rows.indices),
        rowMap.rows.count == target.rows.count
      else {
        throw invalid("The saved Lungfish row map does not match native source row order.")
      }
      let sourceRows: [MultipleSequenceAlignmentBundle.SourceRowMetadata]
      if let metadataURL = input.sourceMetadataURL {
        sourceRows = try decode(
          [MultipleSequenceAlignmentBundle.SourceRowMetadata].self,
          from: metadataURL)
        guard sourceRows.count == rowMap.rows.count,
          Set(sourceRows.map(\.rowName)).count == sourceRows.count,
          Set(sourceRows.map(\.rowID)).count == sourceRows.count
        else {
          throw invalid("The MSA source-row metadata is incomplete or ambiguous.")
        }
      } else {
        sourceRows = []
      }
      let sourceByName = Dictionary(uniqueKeysWithValues: sourceRows.map { ($0.rowName, $0) })
      var rowsByID: [String: PrimalScheme3AlleleLabelMap.Row] = [:]
      for (nativeRow, mappedRow) in zip(target.rows, rowMap.rows) {
        guard allNativeRowIDs.insert(nativeRow.rowID).inserted,
          nativeRow.rowContentSHA256.count == 64,
          nativeRow.rowContentSHA256.allSatisfy({ $0.isHexDigit }),
          nativeRow.fastaDescription == mappedRow.normalizedHeader,
          nativeRow.fastaRecordID == mappedRow.normalizedHeader,
          nativeRow.normalizedRecordID == mappedRow.normalizedHeader,
          nativeRow.fastaComment == nil
        else {
          throw invalid("A native label row is detached from the consumed Lungfish FASTA header.")
        }
        let source = sourceRows.isEmpty ? nil : sourceByName[mappedRow.originalHeader]
        if !sourceRows.isEmpty, source == nil {
          throw invalid("A consumed MSA row has no original source-row metadata.")
        }
        let display = source?.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = display.flatMap { $0.isEmpty ? nil : $0 } ?? mappedRow.originalHeader
        rowsByID[nativeRow.rowID] = .init(
          sourceMSAIndex: target.sourceMSAIndex, inputID: input.id,
          rowIndex: nativeRow.rowIndex, nativeRowID: nativeRow.rowID,
          displayLabel: displayLabel, nativeFASTARecordID: nativeRow.fastaRecordID,
          nativeFASTADescription: nativeRow.fastaDescription,
          normalizedHeader: mappedRow.normalizedHeader, originalHeader: mappedRow.originalHeader,
          lgeRowName: source?.rowName, originalName: source?.originalName,
          stableLGERowID: source?.rowID, sourceSequenceName: source?.sourceSequenceName)
      }
      var targetClassRows = Set<String>()
      for alleleClass in target.classes {
        guard !alleleClass.alleleID.isEmpty, classIDs.insert(alleleClass.alleleID).inserted,
          alleleClass.multiplicity == alleleClass.rowIDs.count,
          alleleClass.rowIDs.count == alleleClass.fastaRecordIDs.count,
          alleleClass.rowIDs.count == alleleClass.fastaDescriptions.count
        else {
          throw invalid("A native allele class label record is malformed or duplicated.")
        }
        var rows: [PrimalScheme3AlleleLabelMap.Row] = []
        for index in alleleClass.rowIDs.indices {
          let rowID = alleleClass.rowIDs[index]
          guard targetClassRows.insert(rowID).inserted, let row = rowsByID[rowID],
            alleleClass.fastaRecordIDs[index] == row.nativeFASTARecordID,
            alleleClass.fastaDescriptions[index] == row.nativeFASTADescription
          else {
            throw invalid("A native allele class is detached from its source row aliases.")
          }
          rows.append(row)
        }
        classes.append(
          .init(
            targetID: target.targetID, alleleID: alleleClass.alleleID,
            multiplicity: alleleClass.multiplicity, rows: rows))
      }
      guard targetClassRows == Set(target.rows.map(\.rowID)) else {
        throw invalid("Native allele classes do not cover each source row exactly once.")
      }
    }
    return .init(
      schemaVersion: PrimalScheme3AlleleLabelMap.schemaVersion,
      resultID: resultID, nativeSchemaVersion: nativeSchema,
      nativeLabelMapRelativePath: nativeMapRelativePath,
      scope:
        "Display labels and immutable ID aliases only; scientific IDs, coverage, objectives, and history are unchanged.",
      classes: classes)
  }

  private static func validateAudit(
    _ data: Data?, reference: NativeReference, map: NativeMap
  ) throws {
    guard let data else {
      throw invalid("The advertised native allele label map has no fresh audit evidence.")
    }
    let audit: NativeAudit
    do { audit = try JSONDecoder().decode(NativeAudit.self, from: data) } catch {
      throw invalid("The native allele label audit evidence is malformed.")
    }
    guard audit.valid, audit.alleleLabelMap?.advertised == true,
      audit.alleleLabelMap?.valid == true,
      audit.alleleLabelMap?.path == reference.path,
      audit.alleleLabelMap?.targets == map.targets.count,
      audit.alleleLabelMap?.rows == map.targets.reduce(0, { $0 + $1.rows.count }),
      audit.alleleLabelMap?.classes == map.targets.reduce(0, { $0 + $1.classes.count })
    else {
      throw invalid("The advertised native allele label map was not freshly audited.")
    }
  }

  private static func descriptor(
    source: URL, published: URL, role: FileRole, format: FileFormat = .json
  ) throws -> ProvenanceFileDescriptor {
    .init(
      path: published.path,
      checksumSHA256: try ProvenanceFileHasher.sha256(of: source),
      fileSize: try ProvenanceFileHasher.fileSize(of: source),
      format: format, role: role, originPath: source.path)
  }

  private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) } catch {
      throw invalid("Allele label metadata is missing or malformed: \(url.lastPathComponent).")
    }
  }

  private static func contained(_ root: URL, relativePath: String) throws -> URL {
    let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
      !relativePath.contains("\0"),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw invalid("The native allele label map uses an unsafe path.")
    }
    let result = root.appendingPathComponent(relativePath).standardizedFileURL
    guard result.path.hasPrefix(root.standardizedFileURL.path + "/") else {
      throw invalid("The native allele label map path escapes its output directory.")
    }
    return result
  }

  private static func relative(_ url: URL, to root: URL) throws -> String {
    let prefix = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(prefix) else {
      throw invalid("Allele label provenance input is outside the workflow scratch directory.")
    }
    return String(path.dropFirst(prefix.count))
  }

  private static func invalid(_ message: String) -> PrimalScheme3DesignError {
    .invalidRequest(message)
  }
}

private struct NativeOptimizer: Decodable {
  let publication: Publication?

  struct Publication: Decodable {
    let alleleLabelMap: NativeReference?
  }
}

private struct NativeReference: Decodable {
  let path: String
  let schemaVersion: String
}

private struct NativeMap: Decodable {
  let schemaVersion: String
  let scientificIdentityRole: String
  let inputs: [Input]
  let targets: [Target]

  struct Input: Decodable {
    let sourceMSAIndex: Int
    let storedPath: String
    let sha256: String
    let size: UInt64

    enum CodingKeys: String, CodingKey {
      case sourceMSAIndex = "source_msa_index"
      case storedPath = "stored_path"
      case sha256, size
    }
  }

  struct Target: Decodable {
    let targetID: String
    let sourceMSAIndex: Int
    let occurrence: Int
    let rows: [Row]
    let classes: [AlleleClass]

    enum CodingKeys: String, CodingKey {
      case targetID = "target_id"
      case sourceMSAIndex = "source_msa_index"
      case occurrence, rows, classes
    }
  }

  struct Row: Decodable {
    let rowIndex: Int
    let rowID: String
    let rowContentSHA256: String
    let fastaDescription: String
    let fastaRecordID: String
    let fastaComment: String?
    let normalizedRecordID: String

    enum CodingKeys: String, CodingKey {
      case rowIndex = "row_index"
      case rowID = "row_id"
      case rowContentSHA256 = "row_content_sha256"
      case fastaDescription = "fasta_description"
      case fastaRecordID = "fasta_record_id"
      case fastaComment = "fasta_comment"
      case normalizedRecordID = "normalized_record_id"
    }
  }

  struct AlleleClass: Decodable {
    let alleleID: String
    let multiplicity: Int
    let rowIDs: [String]
    let fastaRecordIDs: [String]
    let fastaDescriptions: [String]

    enum CodingKeys: String, CodingKey {
      case alleleID = "allele_id"
      case multiplicity
      case rowIDs = "row_ids"
      case fastaRecordIDs = "fasta_record_ids"
      case fastaDescriptions = "fasta_descriptions"
    }
  }
}

private struct RowMap: Decodable {
  let schemaVersion: Int
  let inputID: UUID
  let rows: [Row]

  struct Row: Decodable {
    let rowIndex: Int
    let originalHeader: String
    let normalizedHeader: String
  }
}

private struct NativeAudit: Decodable {
  let valid: Bool
  let alleleLabelMap: LabelMap?

  struct LabelMap: Decodable {
    let advertised: Bool
    let valid: Bool?
    let path: String?
    let targets: Int?
    let rows: Int?
    let classes: Int?
  }

  enum CodingKeys: String, CodingKey {
    case valid
    case alleleLabelMap = "allele_label_map"
  }
}
