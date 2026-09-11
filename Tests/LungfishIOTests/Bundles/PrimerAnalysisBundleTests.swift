import CryptoKit
import Foundation
import XCTest

@testable import LungfishIO

final class PrimerAnalysisBundleTests: XCTestCase {
  func testLoadsOpaqueArtifactAndPreservesIdentityAfterRelocation() throws {
    let temporaryRoot = canonicalTemporaryDirectory()
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let originalRoot = temporaryRoot.appendingPathComponent(
      "original.lungfishprimeranalysis", isDirectory: true)
    let artifactURL = originalRoot.appendingPathComponent("native/unfamiliar.bin")
    let inputURL = originalRoot.appendingPathComponent("inputs/source.txt")
    let provenanceURL = originalRoot.appendingPathComponent("provenance/wrapper.json")
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: inputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: provenanceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("opaque output\n".utf8)
    let inputBytes = Data("opaque input\n".utf8)
    try original.write(to: artifactURL)
    try inputBytes.write(to: inputURL)
    let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    let inputDigest = SHA256.hash(data: inputBytes).map { String(format: "%02x", $0) }.joined()
    let analysisID = UUID()
    let runID = UUID()
    let provenance = Data(
      """
      {"workflowName":"lungfish.primer-analysis.wrap","workflowVersion":"1","tool":{"name":"Lungfish Primer Analysis Storage","version":"1"},"argv":["storage-test-host","--case","opaque-wrap"],"reproducibleCommand":"storage-test-host --case opaque-wrap","options":{"explicit":{},"defaults":{},"resolvedDefaults":{"publication":{"type":"string","value":"exclusive-atomic"},"analysisID":{"type":"string","value":"\(analysisID.uuidString)"},"runID":{"type":"string","value":"\(runID.uuidString)"},"grouping":{"type":"string","value":"independent"}}},"runtimeIdentity":{"appVersion":"test","executablePath":"/test/host","processIdentifier":1,"operatingSystemVersion":"test","architecture":"arm64"},"files":[{"path":"/original/source.txt","role":"input","checksumSHA256":"\(inputDigest)","fileSize":13}],"outputs":[{"path":"/final/inputs/source.txt","checksumSHA256":"\(inputDigest)","fileSize":13},{"path":"/final/native/unfamiliar.bin","checksumSHA256":"\(digest)","fileSize":14}],"exitStatus":0,"wallTimeSeconds":0.01}
      """.utf8)
    try provenance.write(to: provenanceURL)
    let inputID = UUID()
    let resultID = UUID()
    let manifest = PrimerAnalysisManifest(
      schemaVersion: 1,
      analysisID: analysisID,
      runID: runID,
      inputs: [PrimerAnalysisInput(id: inputID, artifactPaths: ["inputs/source.txt"])],
      results: [
        PrimerAnalysisResult(
          id: resultID, inputIDs: [inputID], artifactPaths: ["native/unfamiliar.bin"])
      ],
      artifacts: [
        descriptor("inputs/source.txt", inputBytes, role: "input", format: "text"),
        descriptor("native/unfamiliar.bin", original, role: "nativeOutput", format: "binary"),
      ],
      provenance: descriptor(
        "provenance/wrapper.json", provenance, role: "provenance", format: "json"),
      grouping: .independent,
      publishedRootPath: "/final"
    )
    try JSONEncoder().encode(manifest).write(
      to: originalRoot.appendingPathComponent(PrimerAnalysisManifest.filename))
    let movedRoot = temporaryRoot.appendingPathComponent(
      "moved.lungfishprimeranalysis", isDirectory: true)
    try FileManager.default.moveItem(at: originalRoot, to: movedRoot)

    let reopened = try PrimerAnalysisBundle.load(from: movedRoot)

    XCTAssertEqual(reopened.manifest.analysisID, analysisID)
    XCTAssertEqual(
      try Data(contentsOf: reopened.artifactURL(forRelativePath: "native/unfamiliar.bin")), original
    )
  }

  func testRejectsUnsupportedSchemaDuplicateIdentitiesBrokenReferencesAndUnsafePaths() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inputID = UUID()
    let input = PrimerAnalysisArtifact(
      relativePath: "inputs/source.txt", role: "input", format: "text",
      sha256: String(repeating: "a", count: 64), byteSize: 1)
    let artifact = PrimerAnalysisArtifact(
      relativePath: "native/file.bin", role: "nativeOutput", format: "binary",
      sha256: String(repeating: "c", count: 64), byteSize: 1)
    let provenance = PrimerAnalysisArtifact(
      relativePath: "provenance/wrapper.json", role: "provenance", format: "json",
      sha256: String(repeating: "b", count: 64), byteSize: 1)
    let cases: [PrimerAnalysisManifest] = [
      .init(
        schemaVersion: 99, analysisID: UUID(), runID: UUID(),
        inputs: [.init(id: inputID, artifactPaths: [input.relativePath])], results: [],
        artifacts: [input, artifact], provenance: provenance, grouping: .independent,
        publishedRootPath: "/final"),
      .init(
        analysisID: UUID(), runID: UUID(),
        inputs: [
          .init(id: inputID, artifactPaths: [input.relativePath]),
          .init(id: inputID, artifactPaths: [input.relativePath]),
        ], results: [], artifacts: [input, artifact], provenance: provenance,
        grouping: .independent, publishedRootPath: "/final"),
      .init(
        analysisID: UUID(), runID: UUID(),
        inputs: [.init(id: inputID, artifactPaths: [input.relativePath])],
        results: [.init(id: UUID(), inputIDs: [UUID()], artifactPaths: [artifact.relativePath])],
        artifacts: [input, artifact], provenance: provenance, grouping: .independent,
        publishedRootPath: "/final"),
      .init(
        analysisID: UUID(), runID: UUID(),
        inputs: [.init(id: inputID, artifactPaths: ["../escape"])], results: [],
        artifacts: [
          .init(
            relativePath: "../escape", role: "native-output", format: "binary",
            sha256: String(repeating: "c", count: 64), byteSize: 1)
        ], provenance: provenance, grouping: .independent, publishedRootPath: "/final"),
    ]
    let expected: [PrimerAnalysisBundleError] = [
      .invalidManifest("unsupported schema version"),
      .invalidManifest("duplicate input ID"),
      .invalidManifest("result reference is invalid"),
      .unsafePath("../escape"),
    ]
    for (index, manifest) in cases.enumerated() {
      let bundle = root.appendingPathComponent("case-\(index)", isDirectory: true)
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      try JSONEncoder().encode(manifest).write(
        to: bundle.appendingPathComponent(PrimerAnalysisManifest.filename))
      XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: bundle), "case \(index)") { error in
        XCTAssertEqual(error as? PrimerAnalysisBundleError, expected[index])
      }
    }
  }

  private func descriptor(_ path: String, _ data: Data, role: String, format: String)
    -> PrimerAnalysisArtifact
  {
    PrimerAnalysisArtifact(
      relativePath: path,
      role: role,
      format: format,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteSize: UInt64(data.count)
    )
  }

  private func canonicalTemporaryDirectory() -> URL {
    let path = FileManager.default.temporaryDirectory.path
    return URL(
      fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path, isDirectory: true)
  }
}
