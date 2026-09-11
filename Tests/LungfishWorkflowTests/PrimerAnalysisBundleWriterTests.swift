import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import LungfishIO
@testable import LungfishWorkflow

final class PrimerAnalysisBundleWriterTests: XCTestCase {
  private enum InjectedFailure: Error { case stop }
  func testWritesOpaqueBytesAndCanonicalWrapperProvenance() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("unfamiliar.bin")
    let sourceInputURL = root.appendingPathComponent("source-input.txt")
    let original = Data("opaque output\n".utf8)
    try Data("opaque input\n".utf8).write(to: sourceInputURL)
    try original.write(to: source)
    let upstreamURL = root.appendingPathComponent("upstream.json")
    let upstream = Data("{\"opaque\":true}\n".utf8)
    try upstream.write(to: upstreamURL)
    let destination = root.appendingPathComponent(
      "analysis.lungfishprimeranalysis", isDirectory: true)
    let inputID = UUID()
    let request = PrimerAnalysisBundleWriteRequest(
      analysisID: UUID(), runID: UUID(), grouping: .combined,
      inputs: [PrimerAnalysisInput(id: inputID, artifactPaths: ["inputs/source.txt"])],
      results: [
        PrimerAnalysisResult(
          id: UUID(), inputIDs: [inputID], artifactPaths: ["native/unfamiliar.bin"])
      ],
      artifacts: [
        PrimerAnalysisSourceArtifact(
          sourceURL: sourceInputURL, relativePath: "inputs/source.txt", role: "input",
          format: "text"),
        PrimerAnalysisSourceArtifact(
          sourceURL: source, relativePath: "native/unfamiliar.bin", role: "nativeOutput",
          format: "binary"),
        PrimerAnalysisSourceArtifact(
          sourceURL: upstreamURL, relativePath: "upstream/provenance.json",
          role: "upstream-provenance", format: "json"),
      ],
      destinationURL: destination,
      invocation: PrimerAnalysisWrapperInvocation(
        argv: ["storage-test-host", "--case", "opaque-wrap"], callerVersion: "test-host-1",
        explicitOptions: ["case": .string("opaque-wrap")],
        runtimeIdentity: ProvenanceRuntimeIdentity(
          appVersion: "test", executablePath: "/test/storage-test-host", processIdentifier: 1,
          operatingSystemVersion: "test", architecture: "arm64", user: nil, dependencySet: "test")
      )
    )

    let reopened = try PrimerAnalysisBundleWriter(
      provenanceWriter: ProvenanceWriter(signingProvider: nil)
    ).write(request)

    XCTAssertEqual(reopened.manifest.grouping, .combined)
    XCTAssertEqual(
      try Data(contentsOf: reopened.artifactURL(forRelativePath: "native/unfamiliar.bin")), original
    )
    XCTAssertEqual(
      try Data(contentsOf: reopened.artifactURL(forRelativePath: "upstream/provenance.json")),
      upstream)
    let envelope = try ProvenanceEnvelopeReader.load(
      fromSidecar: reopened.artifactURL(forRelativePath: "provenance/wrapper.json"))
    XCTAssertEqual(envelope?.argv, ["storage-test-host", "--case", "opaque-wrap"])
    XCTAssertTrue(
      envelope?.outputs.contains(where: {
        $0.path == destination.appendingPathComponent("native/unfamiliar.bin").path
      }) == true)
    XCTAssertEqual(envelope?.files.first(where: { $0.role == .input })?.originPath, nil)
    XCTAssertEqual(envelope?.files.first(where: { $0.role == .input })?.path, sourceInputURL.path)
    XCTAssertEqual(envelope?.exitStatus, 0)
    XCTAssertNotNil(envelope?.wallTimeSeconds)
  }

  func testLocalSignerProducesReopenableReferencedSupportInventory() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    try Data("opaque output\n".utf8).write(to: source)
    let destination = root.appendingPathComponent("default-signer.lungfishprimeranalysis")
    let provenanceWriter = ProvenanceWriter(
      signingProvider: LocalProvenanceSigningProvider(
        privateKey: "primer-analysis-storage-test-key"))
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: provenanceWriter).write(
      makeRequest(source: source, destination: destination))
    XCTAssertEqual(
      try PrimerAnalysisBundle.load(from: bundle.url).manifest.analysisID,
      bundle.manifest.analysisID)
    let support = bundle.manifest.artifacts.filter { $0.role == "provenance-support" }
    XCTAssertEqual(support.count, 2)
    for artifact in support {
      XCTAssertNoThrow(try bundle.artifactURL(forRelativePath: artifact.relativePath))
    }
  }

  func testDestinationCollisionPreservesExistingContents() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    try Data("opaque output\n".utf8).write(to: source)
    let destination = root.appendingPathComponent(
      "existing.lungfishprimeranalysis", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinelURL = destination.appendingPathComponent("sentinel")
    let sentinel = Data("keep me\n".utf8)
    try sentinel.write(to: sentinelURL)
    let request = try makeRequest(source: source, destination: destination)

    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(request))
    XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
  }

  func testRelocatedBundleReopensAfterSourcesAreDeleted() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    try Data("opaque input\n".utf8).write(to: source)
    let originalDestination = root.appendingPathComponent("original.lungfishprimeranalysis")
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
      .write(makeRequest(source: source, destination: originalDestination))
    let moved = root.appendingPathComponent("moved.lungfishprimeranalysis")
    try FileManager.default.moveItem(at: originalDestination, to: moved)
    try FileManager.default.removeItem(at: source)

    let reopened = try PrimerAnalysisBundle.load(from: moved)
    XCTAssertEqual(
      try Data(contentsOf: reopened.artifactURL(forRelativePath: "native/file.bin")),
      Data("opaque result\n".utf8))
  }

  func testTamperAndMissingProvenanceAreRejected() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    try Data("opaque output\n".utf8).write(to: source)
    let tampered = root.appendingPathComponent("tampered.lungfishprimeranalysis")
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
      .write(makeRequest(source: source, destination: tampered))
    try Data("changed\n".utf8).write(to: tampered.appendingPathComponent("native/file.bin"))
    XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: tampered))

    let missing = root.appendingPathComponent("missing.lungfishprimeranalysis")
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
      .write(makeRequest(source: source, destination: missing))
    try FileManager.default.removeItem(
      at: missing.appendingPathComponent("provenance/wrapper.json"))
    XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: missing))
  }

  func testSymlinkSourceAndDanglingDestinationAreRejected() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    try Data("opaque output\n".utf8).write(to: source)
    let linkedSource = root.appendingPathComponent("linked.bin")
    try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: source)
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(
          makeRequest(
            source: linkedSource,
            destination: root.appendingPathComponent("linked-source.lungfishprimeranalysis"))))

    let dangling = root.appendingPathComponent("dangling.lungfishprimeranalysis")
    try FileManager.default.createSymbolicLink(
      atPath: dangling.path, withDestinationPath: root.appendingPathComponent("absent").path)
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(makeRequest(source: source, destination: dangling)))
    var info = stat()
    XCTAssertEqual(lstat(dangling.path, &info), 0)
    XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
  }

  func testProvenanceWriterFailureRollsBackOwnedStaging() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    let bytes = Data("opaque output\n".utf8)
    try bytes.write(to: source)
    let destination = root.appendingPathComponent("failed.lungfishprimeranalysis")
    let writer = ProvenanceWriter(
      publicationMutationDidOccur: { _ in throw InjectedFailure.stop }, signingProvider: nil)

    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: writer).write(
        makeRequest(source: source, destination: destination)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
      $0.contains(".failed.lungfishprimeranalysis.staging-")
    }
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testLoaderRejectsArtifactAndParentSymlinksInOtherwiseValidBundles() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.txt")
    try Data("opaque input\n".utf8).write(to: source)
    let external = root.appendingPathComponent("external.bin")
    try Data("opaque result\n".utf8).write(to: external)

    let fileLinkBundle = root.appendingPathComponent("file-link.lungfishprimeranalysis")
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
      .write(makeRequest(source: source, destination: fileLinkBundle))
    let payload = fileLinkBundle.appendingPathComponent("native/file.bin")
    try FileManager.default.removeItem(at: payload)
    try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)
    XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: fileLinkBundle))

    let parentLinkBundle = root.appendingPathComponent("parent-link.lungfishprimeranalysis")
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
      .write(makeRequest(source: source, destination: parentLinkBundle))
    let nativeDirectory = parentLinkBundle.appendingPathComponent("native", isDirectory: true)
    let realDirectory = parentLinkBundle.appendingPathComponent("real-native", isDirectory: true)
    try FileManager.default.moveItem(at: nativeDirectory, to: realDirectory)
    try FileManager.default.createSymbolicLink(
      at: nativeDirectory, withDestinationURL: realDirectory)
    XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: parentLinkBundle))
  }

  func testRehashedMalformedCanonicalProvenanceIsRejected() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.txt")
    try Data("opaque input\n".utf8).write(to: source)
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["files"] = [] },
      { object in
        var options = object["options"] as! [String: Any]
        var resolved = options["resolvedDefaults"] as! [String: Any]
        resolved["analysisID"] = ["type": "string", "value": UUID().uuidString]
        options["resolvedDefaults"] = resolved
        object["options"] = options
      },
      { object in
        var options = object["options"] as! [String: Any]
        var resolved = options["resolvedDefaults"] as! [String: Any]
        resolved["grouping"] = ["type": "array", "value": ["independent"]]
        options["resolvedDefaults"] = resolved
        object["options"] = options
      },
    ]
    for (index, mutation) in mutations.enumerated() {
      let destination = root.appendingPathComponent("malformed-\(index).lungfishprimeranalysis")
      _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(makeRequest(source: source, destination: destination))
      try rewriteProvenanceAndInventory(in: destination, mutation: mutation)
      XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: destination), "mutation \(index)")
    }
  }

  func testRejectsRootSourceWrongExtensionAndSymlinkedDestinationParent() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.txt")
    try Data("opaque input\n".utf8).write(to: source)
    let validRootRequest = try makeRequest(
      source: source, destination: root.appendingPathComponent("root-source.lungfishprimeranalysis")
    )
    let rootSourceRequest = PrimerAnalysisBundleWriteRequest(
      analysisID: validRootRequest.analysisID, runID: validRootRequest.runID,
      grouping: validRootRequest.grouping, inputs: validRootRequest.inputs,
      results: validRootRequest.results,
      artifacts: [
        .init(
          sourceURL: URL(fileURLWithPath: "/"), relativePath: "inputs/source.txt", role: "input",
          format: "text")
      ] + Array(validRootRequest.artifacts.dropFirst()),
      destinationURL: validRootRequest.destinationURL, invocation: validRootRequest.invocation)
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(rootSourceRequest))
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(
          makeRequest(source: source, destination: root.appendingPathComponent("wrong.bundle"))))
    let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    let linkedParent = root.appendingPathComponent("linked-parent", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(
          makeRequest(
            source: source,
            destination: linkedParent.appendingPathComponent("linked.lungfishprimeranalysis"))))
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: realParent.path)).isEmpty)
  }

  func testLoaderRejectsDuplicateArtifactPathInValidBundle() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.txt")
    try Data("opaque input\n".utf8).write(to: source)
    let destination = root.appendingPathComponent("duplicate.lungfishprimeranalysis")
    _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
      .write(makeRequest(source: source, destination: destination))
    let manifestURL = destination.appendingPathComponent(PrimerAnalysisManifest.filename)
    let old = try JSONDecoder().decode(
      PrimerAnalysisManifest.self, from: Data(contentsOf: manifestURL))
    let duplicate = PrimerAnalysisManifest(
      schemaVersion: old.schemaVersion, analysisID: old.analysisID, runID: old.runID,
      inputs: old.inputs, results: old.results, artifacts: old.artifacts + [old.artifacts[0]],
      provenance: old.provenance, grouping: old.grouping, publishedRootPath: old.publishedRootPath)
    try JSONEncoder().encode(duplicate).write(to: manifestURL)
    XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: destination))
  }

  func testWriterRejectsMissingRequiredRolesAndReservedSupportSpoofing() throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.txt")
    try Data("opaque input\n".utf8).write(to: source)
    let base = try makeRequest(
      source: source, destination: root.appendingPathComponent("roles.lungfishprimeranalysis"))
    let noNative = PrimerAnalysisBundleWriteRequest(
      analysisID: base.analysisID, runID: base.runID, grouping: base.grouping,
      inputs: base.inputs, results: base.results,
      artifacts: base.artifacts.map {
        .init(
          sourceURL: $0.sourceURL, relativePath: $0.relativePath, role: "input",
          format: $0.format)
      }, destinationURL: base.destinationURL, invocation: base.invocation)
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(noNative))

    let spoofed = PrimerAnalysisBundleWriteRequest(
      analysisID: base.analysisID, runID: base.runID, grouping: base.grouping,
      inputs: base.inputs, results: base.results,
      artifacts: base.artifacts + [
        .init(
          sourceURL: base.artifacts[1].sourceURL,
          relativePath: "native/spoof.sig", role: "provenance-support",
          format: base.artifacts[1].format),
      ], destinationURL: base.destinationURL, invocation: base.invocation)
    XCTAssertThrowsError(
      try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        .write(spoofed))
  }

  private func rewriteProvenanceAndInventory(
    in bundle: URL, mutation: (inout [String: Any]) -> Void
  ) throws {
    let provenanceURL = bundle.appendingPathComponent("provenance/wrapper.json")
    var original =
      try JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as! [String: Any]
    mutation(&original)
    let changed = try JSONSerialization.data(
      withJSONObject: original, options: [.prettyPrinted, .sortedKeys])
    try changed.write(to: provenanceURL)
    let manifestURL = bundle.appendingPathComponent(PrimerAnalysisManifest.filename)
    let old = try JSONDecoder().decode(
      PrimerAnalysisManifest.self, from: Data(contentsOf: manifestURL))
    let descriptor = PrimerAnalysisArtifact(
      relativePath: old.provenance.relativePath, role: old.provenance.role,
      format: old.provenance.format,
      sha256: SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined(),
      byteSize: UInt64(changed.count))
    let updated = PrimerAnalysisManifest(
      schemaVersion: old.schemaVersion, analysisID: old.analysisID, runID: old.runID,
      inputs: old.inputs, results: old.results, artifacts: old.artifacts, provenance: descriptor,
      grouping: old.grouping, publishedRootPath: old.publishedRootPath)
    try JSONEncoder().encode(updated).write(to: manifestURL)
  }

  private func makeRequest(source: URL, destination: URL) throws -> PrimerAnalysisBundleWriteRequest
  {
    let inputID = UUID()
    let resultSource = source.deletingLastPathComponent().appendingPathComponent(
      "result-\(source.lastPathComponent)")
    if !FileManager.default.fileExists(atPath: resultSource.path) {
      try Data("opaque result\n".utf8).write(to: resultSource)
    }
    return .init(
      analysisID: UUID(), runID: UUID(), grouping: .independent,
      inputs: [.init(id: inputID, artifactPaths: ["inputs/source.txt"])], results: [],
      artifacts: [
        .init(sourceURL: source, relativePath: "inputs/source.txt", role: "input", format: "text"),
        .init(
          sourceURL: resultSource, relativePath: "native/file.bin", role: "nativeOutput",
          format: "binary"),
      ], destinationURL: destination,
      invocation: .init(
        argv: ["storage-test-host", "--case", "opaque-wrap"], callerVersion: "1",
        explicitOptions: ["case": .string("opaque-wrap")], runtimeIdentity: .init()))
  }

  private func canonicalTemporaryDirectory() -> URL {
    let path = FileManager.default.temporaryDirectory.path
    return URL(
      fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path, isDirectory: true)
  }
}
