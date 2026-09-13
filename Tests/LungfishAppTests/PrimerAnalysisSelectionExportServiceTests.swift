import Foundation
import Darwin
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class PrimerAnalysisSelectionExportServiceTests: XCTestCase {
  func testPrimerFASTARetainsStoredReverseOligoOrientationAndAlternatives() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let amplicon = try XCTUnwrap(target.intervals.first)
    let prepared = try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .amplicon(targetID: target.id, ampliconID: amplicon.id), kind: .primerFASTA)
    XCTAssertEqual(prepared.records.map(\.sequence), ["CC", "CR", "TT"])
    XCTAssertEqual(Set(prepared.records.map(\.name)).count, 3)
    XCTAssertTrue(prepared.fasta.contains("strand=-"))
    XCTAssertTrue(prepared.fasta.contains("pool=1"))
    XCTAssertNil(prepared.annotationBED)
  }

  func testAmpliconExtractsSavedReferenceForwardSpanAndShiftsAnnotations() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let amplicon = try XCTUnwrap(target.intervals.first)
    let prepared = try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .amplicon(targetID: target.id, ampliconID: amplicon.id), kind: .referenceAmplicon)
    XCTAssertEqual(prepared.records.map(\.sequence), ["CCGGTTAA"])
    XCTAssertEqual(prepared.options["sourceStart"], .integer(2))
    XCTAssertEqual(prepared.options["sourceEnd"], .integer(10))
    XCTAssertEqual(prepared.options["sequenceSemantics"], .string("saved-reference-span-including-primers"))
    let bed = try XCTUnwrap(prepared.annotationBED)
    XCTAssertTrue(bed.contains("\t0\t2\tfixture_1_LEFT_0\t"))
    XCTAssertTrue(bed.contains("\t6\t8\tfixture_1_RIGHT_0\t"))
    XCTAssertTrue(bed.contains("sequence_5prime_to_3prime=TT"))
  }

  func testUnknownSelectionsAndNonAmpliconExtractionAreRejected() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    XCTAssertThrowsError(try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .primer(targetID: target.id, primerID: "invented"), kind: .primerFASTA))
    XCTAssertThrowsError(try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .pool(sourceResultID: target.sourceResultID, pool: 99), kind: .primerFASTA))
    XCTAssertThrowsError(try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .referenceAmplicon))
  }

  func testPrimer3ProbeUsesNormalizedOligoIdentityForAnnotationType() throws {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    free(physical)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
    let pair = Primer3Pair(id: UUID(),
      left: .init(id: UUID(), start: 2, end: 4, orientation: .forward, sequence: "CC", meltingTemperature: 60, gcPercent: 100),
      right: .init(id: UUID(), start: 8, end: 10, orientation: .reverse, sequence: "TT", meltingTemperature: 60, gcPercent: 0),
      internalOligo: .init(id: UUID(), start: 4, end: 6, orientation: .forward, sequence: "GG", meltingTemperature: 65, gcPercent: 100),
      productSize: 8)
    let normalized = Primer3NormalizedResults(analysisID: analysisID, runID: runID,
      results: [.init(resultID: resultID, inputID: inputID, title: "Synthetic saved probe", sourceKind: "fasta",
        sourceIndex: 0, sourceRecordID: "reference", templateSequence: "AACCGGTTAACC", alignmentToTemplate: nil,
        excludedRegions: [], pairs: [pair], error: nil, explanation: nil)])
    let input = root.appendingPathComponent("input.fasta"), json = root.appendingPathComponent("normalized.json")
    try Data(">reference\nAACCGGTTAACC\n".utf8).write(to: input)
    try JSONEncoder().encode(normalized).write(to: json)
    let path = "results/primer3-normalized-v1.json"
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
      analysisID: analysisID, runID: runID, grouping: .independent,
      inputs: [.init(id: inputID, artifactPaths: ["inputs/template.fasta"])],
      results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])], artifacts: [
        .init(sourceURL: input, relativePath: "inputs/template.fasta", role: "input", format: "fasta"),
        .init(sourceURL: json, relativePath: path, role: "nativeOutput", format: "json")],
      destinationURL: root.appendingPathComponent("probe.lungfishprimeranalysis"),
      invocation: .init(argv: ["stored-probe-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: bundle.url)
    let prepared = try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .amplicon(targetID: pair.id.uuidString, ampliconID: pair.id.uuidString), kind: .referenceAmplicon)
    let rows = try XCTUnwrap(prepared.annotationBED).split(whereSeparator: \.isNewline)
      .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    XCTAssertEqual(rows.map { $0[12] }, ["primer_bind", "primer_bind", "internal_oligo"])
    XCTAssertEqual(rows[2][1], "2")
    XCTAssertEqual(rows[2][2], "4")
    XCTAssertTrue(rows[2][13].contains("source_primer_id=\(pair.internalOligo!.id.uuidString)"))
  }

  func testPublishedBundleRetainsPayloadSourceEvidenceAndFinalProvenance() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let destination = fixture.root.appendingPathComponent("selected.lungfishref")
    let before = try files(in: fixture.bundle)
    let output = try await PrimerAnalysisSelectionExportService().export(analysisURL: fixture.bundle,
      selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA,
      destinationURL: destination, invocationArgv: ["lungfish-app", "primer-analysis", "export-pool", "--pool", "1"])
    XCTAssertEqual(output, destination)
    XCTAssertEqual(try files(in: fixture.bundle), before)
    let manifest = try BundleManifest.load(from: output)
    XCTAssertEqual(manifest.genome?.chromosomes.count, 3)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("primers.fasta").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("selection.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("source-analysis/manifest.json").path))
    let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
    XCTAssertEqual(envelope.exitStatus, 0)
    XCTAssertNotNil(envelope.wallTimeSeconds)
    XCTAssertEqual(envelope.options.resolvedDefaults["pool"], .integer(1))
    XCTAssertFalse(envelope.outputs.isEmpty)
    for step in envelope.steps {
      XCTAssertFalse((step.durableReplayArgv ?? step.argv).contains { $0.contains(".primer-selection-") })
      XCTAssertFalse(step.reproducibleCommand.contains(".primer-selection-"))
    }
    for descriptor in envelope.outputs {
      XCTAssertTrue(descriptor.path.hasPrefix(output.path + "/"), descriptor.path)
      let file = URL(fileURLWithPath: descriptor.path)
      XCTAssertEqual(try ProvenanceFileHasher.sha256(of: file), descriptor.checksumSHA256)
      XCTAssertEqual(try ProvenanceFileHasher.fileSize(of: file), descriptor.fileSize)
    }
  }

  func testPublicationGuardFailureAndExistingDestinationLeaveNoNewOutput() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let destination = fixture.root.appendingPathComponent("blocked.lungfishref")
    enum Blocked: Error { case projectChanged }
    do {
      _ = try await PrimerAnalysisSelectionExportService().export(analysisURL: fixture.bundle,
        selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA,
        destinationURL: destination, invocationArgv: ["test-export"], publish: { _, _ in throw Blocked.projectChanged })
      XCTFail("Expected publication guard rejection")
    } catch Blocked.projectChanged { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent("sentinel")
    try Data("preserve".utf8).write(to: sentinel)
    do {
      _ = try await PrimerAnalysisSelectionExportService().export(analysisURL: fixture.bundle,
        selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA,
        destinationURL: destination, invocationArgv: ["test-export"])
      XCTFail("Expected collision rejection")
    } catch { }
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".primer-selection-") })
  }

  func testSignedSourceProvenanceRemainsVerifiableAfterOriginalIsUnavailable() async throws {
    let fixture = try makeFixture(signed: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let sourceProvenancePath = snapshot.bundle.manifest.provenance.relativePath
    let support = snapshot.bundle.manifest.artifacts.filter { $0.role == "provenance-support" }
    XCTAssertEqual(support.count, 2)
    let sourceBytes = try ([snapshot.bundle.manifest.provenance] + support).map { artifact in
      (artifact, try Data(contentsOf: snapshot.bundle.artifactURL(forRelativePath: artifact.relativePath)))
    }
    let destination = fixture.root.appendingPathComponent("signed-source-selection.lungfishref")
    let output = try await PrimerAnalysisSelectionExportService().export(analysisURL: fixture.bundle,
      selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA,
      destinationURL: destination, invocationArgv: ["test-export-signed-source", "--pool", "1"])
    try FileManager.default.removeItem(at: fixture.bundle)
    let retainedProvenance = output.appendingPathComponent("source-analysis/" + sourceProvenancePath)
    XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: retainedProvenance).isValid)
    let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
    for (artifact, bytes) in sourceBytes {
      let retained = output.appendingPathComponent("source-analysis/" + artifact.relativePath)
      XCTAssertEqual(try Data(contentsOf: retained), bytes)
      let descriptor = try XCTUnwrap(envelope.outputs.first { $0.path == retained.path })
      XCTAssertEqual(descriptor.checksumSHA256, artifact.sha256)
      XCTAssertEqual(descriptor.fileSize, artifact.byteSize)
    }
  }

  func testTamperedSavedPrimersAreRejectedBeforePublication() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    try Data("tampered".utf8).write(to: fixture.bundle.appendingPathComponent("native/primer.bed"))
    let destination = fixture.root.appendingPathComponent("corrupt.lungfishref")
    do {
      _ = try await PrimerAnalysisSelectionExportService().export(analysisURL: fixture.bundle,
        selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA,
        destinationURL: destination, invocationArgv: ["test-export"])
      XCTFail("Expected integrity failure")
    } catch { XCTAssertTrue(error.localizedDescription.contains("integrity")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private func makeFixture(signed: Bool = false) throws -> (root: URL, bundle: URL) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    free(physical)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inputID = UUID(), resultID = UUID()
    let payloads = [
      "inputs/source.fasta": ">reference\nAACCGGTTAACC\n",
      "native/reference.fasta": ">reference\nAACCGGTTAACC\n",
      "native/primer.bed": "reference\t2\t4\tfixture_1_LEFT_0\t1\t+\tCC\nreference\t2\t4\tfixture_1_LEFT_1\t1\t+\tCR\nreference\t8\t10\tfixture_1_RIGHT_0\t1\t-\tTT\n",
      "native/amplicon.bed": "reference\t2\t10\tfixture_1\t1\n",
    ]
    let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
      let source = root.appendingPathComponent(UUID().uuidString)
      try Data(text.utf8).write(to: source)
      return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path,
        role: path.hasPrefix("inputs/") ? "input" : "nativeOutput", format: path.hasSuffix(".bed") ? "bed" : "fasta")
    }
    let provenanceWriter = ProvenanceWriter(signingProvider: signed
      ? LocalProvenanceSigningProvider(privateKey: "primer-selection-export-test-key") : nil)
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: provenanceWriter).write(.init(
      analysisID: UUID(), runID: UUID(), grouping: .independent,
      inputs: [.init(id: inputID, artifactPaths: ["inputs/source.fasta"])],
      results: [.init(id: resultID, label: "Stored synthetic MHC display example", inputIDs: [inputID],
        artifactPaths: payloads.keys.filter { $0.hasPrefix("native/") }.sorted())], artifacts: artifacts,
      destinationURL: root.appendingPathComponent("source.lungfishprimeranalysis"),
      invocation: .init(argv: ["stored-display-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, bundle.url)
  }

  private func files(in root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      files[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
    }
    return files
  }
}
