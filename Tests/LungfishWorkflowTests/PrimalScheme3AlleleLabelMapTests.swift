import Foundation
import LungfishIO
import XCTest

@testable import LungfishWorkflow

final class PrimalScheme3AlleleLabelMapTests: XCTestCase {
  func testPublishesOriginalLabelsStableRowsAndCompleteTransformProvenance() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let publication = try XCTUnwrap(
      PrimalScheme3AlleleLabelBridge.publishIfAdvertised(
        nativeOutputURL: fixture.nativeOutput,
        inputs: fixture.inputs,
        resultID: fixture.resultID,
        scratchRootURL: fixture.scratch,
        publishedRootURL: fixture.published,
        invocation: .init(
          argv: ["lungfish-cli", "primers", "design", "primalscheme3"],
          callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()),
        auditValidation: fixture.auditValidation,
        auditValidationURL: fixture.auditValidationURL))

    XCTAssertEqual(publication.artifacts.map(\.role), ["derived-label-map", "derivedProvenance"])
    XCTAssertEqual(publication.resultArtifactPaths, publication.artifacts.map(\.relativePath))
    let map = try JSONDecoder().decode(
      PrimalScheme3AlleleLabelMap.self, from: Data(contentsOf: publication.artifacts[0].sourceURL))
    XCTAssertEqual(map.schemaVersion, "lungfish.primer-analysis.allele-label-map/v1")
    XCTAssertEqual(map.resultID, fixture.resultID)
    XCTAssertEqual(map.classes.map(\.alleleID), ["ObservedAllele-a", "ObservedAllele-b"])
    XCTAssertEqual(map.classes[0].multiplicity, 2)
    XCTAssertEqual(map.classes[0].rows.map(\.displayLabel), ["Mamu-A1*001:01", "Mamu-A1*001:01"])
    XCTAssertEqual(map.classes[0].rows.map(\.stableLGERowID), ["stable-row-1", "stable-row-2"])
    XCTAssertEqual(map.classes[0].rows.map(\.nativeRowID), ["row-a", "row-b"])
    XCTAssertEqual(map.classes[1].rows.first?.displayLabel, "raw original header")
    XCTAssertNil(map.classes[1].rows.first?.stableLGERowID)

    let envelope = try ProvenanceEnvelopeReader.decodeCanonical(
      Data(contentsOf: publication.artifacts[1].sourceURL))
    XCTAssertEqual(envelope.workflowName, "lungfish.primalscheme3.allele-label-enrichment")
    XCTAssertEqual(envelope.exitStatus, 0)
    let consumed = Set(envelope.files.map(\.path))
    XCTAssertTrue(
      consumed.contains(
        fixture.published.appendingPathComponent(
          "native/\(fixture.resultID.uuidString)/allele-label-map.json"
        ).path))
    XCTAssertTrue(
      consumed.contains(
        fixture.published.appendingPathComponent(
          "native/\(fixture.resultID.uuidString)/panel-optimizer.json"
        ).path))
    XCTAssertTrue(
      consumed.contains(
        fixture.published.appendingPathComponent(
          "native/\(fixture.resultID.uuidString)/work/0000-input.fasta"
        ).path))
    XCTAssertTrue(
      consumed.contains(
        fixture.published.appendingPathComponent(
          "logs/\(fixture.resultID.uuidString)/panel-audit-validation.json"
        ).path))
    XCTAssertTrue(
      fixture.inputs.allSatisfy {
        consumed.contains(
          fixture.published.appendingPathComponent(
            $0.rowMappingURL.path.replacingOccurrences(of: fixture.scratch.path + "/", with: "")
          ).path)
      })
    let metadata = try XCTUnwrap(fixture.inputs[0].sourceMetadataURL)
    XCTAssertTrue(
      consumed.contains(
        fixture.published.appendingPathComponent(
          metadata.path.replacingOccurrences(of: fixture.scratch.path + "/", with: "")
        ).path))
    XCTAssertEqual(
      envelope.outputs.map(\.path),
      [
        fixture.published.appendingPathComponent(publication.artifacts[0].relativePath).path
      ])
  }

  func testHistoricalOutputWithoutAdvertisedMapRemainsCompatible() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try writeJSON(
      ["schemaVersion": "primalscheme3.panel-optimizer/v2"],
      to: fixture.nativeOutput.appendingPathComponent("panel-optimizer.json"))

    XCTAssertNil(
      try PrimalScheme3AlleleLabelBridge.publishIfAdvertised(
        nativeOutputURL: fixture.nativeOutput, inputs: fixture.inputs,
        resultID: fixture.resultID, scratchRootURL: fixture.scratch,
        publishedRootURL: fixture.published, invocation: hostInvocation,
        auditValidation: nil, auditValidationURL: nil))
  }

  func testAdvertisedMapRequiresFreshRetainedAudit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try PrimalScheme3AlleleLabelBridge.publishIfAdvertised(
        nativeOutputURL: fixture.nativeOutput, inputs: fixture.inputs,
        resultID: fixture.resultID, scratchRootURL: fixture.scratch,
        publishedRootURL: fixture.published, invocation: hostInvocation,
        auditValidation: fixture.auditValidation, auditValidationURL: nil))
  }

  func testAdvertisedMapRejectsRetainedAuditDifferentFromValidatedBytes() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("{}".utf8).write(to: fixture.auditValidationURL)

    XCTAssertThrowsError(
      try PrimalScheme3AlleleLabelBridge.publishIfAdvertised(
        nativeOutputURL: fixture.nativeOutput, inputs: fixture.inputs,
        resultID: fixture.resultID, scratchRootURL: fixture.scratch,
        publishedRootURL: fixture.published, invocation: hostInvocation,
        auditValidation: fixture.auditValidation,
        auditValidationURL: fixture.auditValidationURL))
  }

  func testAdvertisedMapRejectsDetachedNormalizedRowHeader() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = fixture.inputs[0]
    try writeJSON(
      [
        "schemaVersion": 1, "inputID": first.id.uuidString,
        "rows": [
          ["rowIndex": 0, "originalHeader": "aligned-a", "normalizedHeader": "detached"],
          ["rowIndex": 1, "originalHeader": "aligned-b", "normalizedHeader": "input_a_row_1"],
        ],
      ], to: first.rowMappingURL)

    XCTAssertThrowsError(
      try PrimalScheme3AlleleLabelBridge.publishIfAdvertised(
        nativeOutputURL: fixture.nativeOutput, inputs: fixture.inputs,
        resultID: fixture.resultID, scratchRootURL: fixture.scratch,
        publishedRootURL: fixture.published, invocation: hostInvocation,
        auditValidation: fixture.auditValidation,
        auditValidationURL: fixture.auditValidationURL))
  }

  private var hostInvocation: PrimerAnalysisWrapperInvocation {
    .init(
      argv: ["lungfish-cli", "primers", "design", "primalscheme3"],
      callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())
  }

  private struct Fixture {
    let root: URL
    let scratch: URL
    let published: URL
    let nativeOutput: URL
    let resultID: UUID
    let inputs: [PrimalScheme3AlleleLabelBridge.Input]
    let auditValidation: Data
    let auditValidationURL: URL
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let scratch = root.appendingPathComponent("scratch")
    let resultID = UUID()
    let native = scratch.appendingPathComponent("native/\(resultID.uuidString)")
    try FileManager.default.createDirectory(
      at: native.appendingPathComponent("work"), withIntermediateDirectories: true)
    let firstID = UUID()
    let secondID = UUID()
    let firstMap = scratch.appendingPathComponent("inputs/\(firstID.uuidString)-row-map.json")
    let secondMap = scratch.appendingPathComponent("inputs/\(secondID.uuidString)-row-map.json")
    try FileManager.default.createDirectory(
      at: firstMap.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try writeJSON(
      [
        "schemaVersion": 1, "inputID": firstID.uuidString,
        "rows": [
          ["rowIndex": 0, "originalHeader": "aligned-a", "normalizedHeader": "input_a_row_0"],
          ["rowIndex": 1, "originalHeader": "aligned-b", "normalizedHeader": "input_a_row_1"],
        ],
      ], to: firstMap)
    try writeJSON(
      [
        "schemaVersion": 1, "inputID": secondID.uuidString,
        "rows": [
          [
            "rowIndex": 0, "originalHeader": "raw original header",
            "normalizedHeader": "input_b_row_0",
          ]
        ],
      ], to: secondMap)
    let sourceMetadata = scratch.appendingPathComponent(
      "source-inputs/\(firstID.uuidString)/source.lungfishmsa/metadata/source-row-map.json")
    try FileManager.default.createDirectory(
      at: sourceMetadata.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try writeJSON(
      [
        [
          "rowID": "stable-row-1", "rowName": "aligned-a", "originalName": "Mamu-A1*001:01",
          "sourceSequenceName": "source-a", "sourceFilePath": "a.fa", "sourceFormat": "fasta",
          "sourceChecksumSHA256": String(repeating: "a", count: 64),
        ],
        [
          "rowID": "stable-row-2", "rowName": "aligned-b", "originalName": "Mamu-A1*001:01",
          "sourceSequenceName": "source-b", "sourceFilePath": "b.fa", "sourceFormat": "fasta",
          "sourceChecksumSHA256": String(repeating: "b", count: 64),
        ],
      ], to: sourceMetadata)
    let storedA = native.appendingPathComponent("work/0000-input.fasta")
    let storedB = native.appendingPathComponent("work/0001-input.fasta")
    try Data(">input_a_row_0\nACGT\n>input_a_row_1\nACGT\n".utf8).write(to: storedA)
    try Data(">input_b_row_0\nTGCA\n".utf8).write(to: storedB)
    func inputDescriptor(_ index: Int, _ path: URL) throws -> [String: Any] {
      [
        "source_msa_index": index, "stored_path": "work/\(path.lastPathComponent)",
        "sha256": try ProvenanceFileHasher.sha256(of: path),
        "size": Int(try ProvenanceFileHasher.fileSize(of: path)),
      ]
    }
    let nativeMap: [String: Any] = [
      "schemaVersion": "primalscheme3.allele-label-map/v1",
      "scientificIdentityRole": "display-only-excluded",
      "scope": "display only",
      "inputs": [try inputDescriptor(0, storedA), try inputDescriptor(1, storedB)],
      "targets": [
        [
          "target_id": "target-a", "source_msa_index": 0, "occurrence": 0,
          "rows": [
            nativeRow(0, "row-a", "input_a_row_0"), nativeRow(1, "row-b", "input_a_row_1"),
          ],
          "classes": [
            [
              "allele_id": "ObservedAllele-a", "multiplicity": 2,
              "row_ids": ["row-a", "row-b"],
              "fasta_record_ids": ["input_a_row_0", "input_a_row_1"],
              "fasta_descriptions": ["input_a_row_0", "input_a_row_1"],
            ]
          ],
        ],
        [
          "target_id": "target-b", "source_msa_index": 1, "occurrence": 0,
          "rows": [nativeRow(0, "row-c", "input_b_row_0")],
          "classes": [
            [
              "allele_id": "ObservedAllele-b", "multiplicity": 1,
              "row_ids": ["row-c"], "fasta_record_ids": ["input_b_row_0"],
              "fasta_descriptions": ["input_b_row_0"],
            ]
          ],
        ],
      ],
    ]
    try writeJSON(nativeMap, to: native.appendingPathComponent("allele-label-map.json"))
    try writeJSON(
      [
        "schemaVersion": "primalscheme3.panel-optimizer/v2",
        "publication": [
          "alleleLabelMap": [
            "path": "allele-label-map.json",
            "schemaVersion": "primalscheme3.allele-label-map/v1",
          ]
        ],
      ], to: native.appendingPathComponent("panel-optimizer.json"))
    let audit = try JSONSerialization.data(
      withJSONObject: [
        "valid": true,
        "allele_label_map": [
          "advertised": true, "valid": true,
          "path": "allele-label-map.json", "targets": 2, "rows": 3, "classes": 2,
        ],
      ], options: [.sortedKeys])
    let auditURL = scratch.appendingPathComponent(
      "logs/\(resultID.uuidString)/panel-audit-validation.json")
    try FileManager.default.createDirectory(
      at: auditURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try audit.write(to: auditURL)
    return .init(
      root: root, scratch: scratch,
      published: root.appendingPathComponent("result.lungfishprimeranalysis"),
      nativeOutput: native, resultID: resultID,
      inputs: [
        .init(id: firstID, rowMappingURL: firstMap, sourceMetadataURL: sourceMetadata),
        .init(id: secondID, rowMappingURL: secondMap, sourceMetadataURL: nil),
      ],
      auditValidation: audit, auditValidationURL: auditURL)
  }

  private func nativeRow(_ index: Int, _ id: String, _ header: String) -> [String: Any] {
    [
      "row_index": index, "row_id": id, "row_content_sha256": String(repeating: "c", count: 64),
      "fasta_description": header, "fasta_record_id": header, "fasta_comment": NSNull(),
      "normalized_record_id": header,
    ]
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
  }
}
