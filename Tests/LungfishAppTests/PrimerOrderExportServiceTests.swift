import CryptoKit
import Darwin
import Foundation
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class PrimerOrderExportServiceTests: XCTestCase {
  func testNativeHumanAndMacaqueFilteredOrders() async throws {
    guard let fixturePath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_ORDER_FIXTURES"],
      let outputPath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_ORDER_OUTPUT"] else {
      throw XCTSkip("Set native MHC fixtures and output directories for manual ordering verification")
    }
    let root = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["human-A-wide", "macaque-DQ-wide"] {
      let input = URL(fileURLWithPath: fixturePath).appendingPathComponent(name + ".lungfishprimeranalysis")
      let snapshot = try PrimerAnalysisViewerSnapshot.load(from: input)
      let before = try fileBytes(input)
      let session = PrimerAnalysisDisplaySession()
      session.configure(snapshot); session.onOrderExportRequested = { _, _ in }
      session.computeCompatibility()
      for _ in 0..<1000 where session.isComputingCompatibility { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(session.compatibilityReady, session.compatibilityError ?? "Comparison timed out")
      session.settings.filterByCompatibility = true
      session.settings.minimumCompatibilityPercent = 60 // Exercise a display filter, not an assay recommendation.
      if let primer = snapshot.designReview.first?.primers.first { session.setPrimerShown(primer.id, shown: false) }
      let captured = try session.makeOrderDraft()
      XCTAssertGreaterThan(captured.oligos.count, 0)
      XCTAssertLessThan(captured.oligos.count, session.totalCount)
      let output = try await PrimerOrderExportService().export(selection: captured.selection,
        metadata: .init(name: name + " filtered order", project: "MHC export verification"),
        destinationURL: root.appendingPathComponent(name), invocationArgv: CommandLine.arguments)
      let reopened = try PrimerOrderExportService.load(from: output)
      XCTAssertEqual(reopened.oligos, captured.oligos)
      XCTAssertEqual(reopened.selection, captured.selection)
      XCTAssertEqual(try fileBytes(input), before)
      let inspector = InspectorViewController()
      inspector.beginPrimerOrderDocument(at: output)
      inspector.updatePrimerOrderDocument(try PrimerOrderExportService.loadSnapshot(from: output), at: output)
      XCTAssertEqual(inspector.viewModel.availableTabs, [.bundle, .files, .provenance])
      XCTAssertEqual(inspector.viewModel.primerAnalysisDocument?.order?.oligos.count, captured.oligos.count)
      XCTAssertNil(inspector.viewModel.primerAnalysisDocument?.errorMessage)
      print("ORDER_VALIDATION \(name): \(captured.oligos.count)/\(session.totalCount) displayed oligos -> \(output.path)")
    }
  }

  func testConfigureCalculatesMatchSummariesWithoutEnablingFilters() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let primer = try XCTUnwrap(snapshot.designReview.first?.primers.first)
    let sequence = primer.sequence
    let different = String(sequence.first == "A" ? "C" : "A") + sequence.dropFirst()
    snapshot.bindingContexts = [.init(id: "match-fixture", title: "Synthetic alignment", alignedFASTA: "", annotations: [],
      primers: [.init(id: "binding", name: primer.name, sequence: sequence, strand: "+", alignedStart: 0,
        alignedEnd: sequence.count, contiguousReference: true, reviewPrimerID: primer.id)],
      unavailableReason: nil, rows: [.init(name: "match", sequence: Array(sequence)),
        .init(name: "difference", sequence: Array(different)),
        .init(name: "unknown", sequence: Array(String(repeating: "N", count: sequence.count)))])]
    let session = PrimerAnalysisDisplaySession()
    session.configure(snapshot)
    XCTAssertTrue(session.isComputingCompatibility)
    XCTAssertFalse(session.settings.filterByCompatibility)
    for _ in 0..<200 where session.isComputingCompatibility { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(session.compatibilityReady, session.compatibilityError ?? "Timed out")
    XCTAssertEqual(session.compatibilitySummaries[primer.id],
      .init(matchingRows: 1, assessableRows: 2, totalRows: 3))
    XCTAssertEqual(session.visibleCount, session.totalCount)
    session.invalidate()
    XCTAssertTrue(session.compatibilitySummaries.isEmpty)
  }

  func testCaptureUsesAllDisplayedTargetsAndRemainsFrozenAfterToggles() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let session = PrimerAnalysisDisplaySession()
    session.configure(snapshot)
    XCTAssertNotNil(session.orderExportUnavailableReason)
    session.onOrderExportRequested = { _, _ in }
    XCTAssertNil(session.orderExportUnavailableReason)
    session.setPrimerShown(snapshot.designReview[0].primers[1].id, shown: false)
    let draft = try session.makeOrderDraft()
    XCTAssertEqual(draft.oligos.count, 5)
    XCTAssertEqual(Set(draft.oligos.map(\.poolName)), ["Scheme_1_Pool_1", "Scheme_2_Pool_1"])
    XCTAssertEqual(draft.oligos.map(\.sequence), ["CC", "TT", "CC", "CR", "TT"])
    session.settings.showForward = false
    session.settings.showReverse = false
    XCTAssertEqual(session.visibleCount, 0)
    XCTAssertNotNil(session.orderExportUnavailableReason)
    XCTAssertEqual(try PrimerOrderExportService.prepare(snapshot: snapshot, selection: draft.selection), draft.oligos)
    XCTAssertEqual(draft.selection.selectedPrimerIDs.count, 5)
    session.reset()
    session.settings.filterByCompatibility = true
    XCTAssertNotNil(session.orderExportUnavailableReason)
    XCTAssertThrowsError(try session.makeOrderDraft())
    session.cancel()
    XCTAssertNotNil(session.orderExportUnavailableReason)
    session.invalidate()
    XCTAssertThrowsError(try session.makeOrderDraft())
  }

  func testRejectsStaleSourceAndContradictorySelection() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let valid = try draft(snapshot).selection
    func changed(ids: [String], ready: Bool = false, settings: PrimerAnalysisDisplaySettings = .init(),
      url: URL? = nil) -> PrimerOrderSelection {
      .init(capturedAt: valid.capturedAt, analysisURL: url ?? valid.analysisURL, manifest: valid.manifest,
        settings: settings, compatibilityReady: ready, compatibilitySummaries: [:], selectedPrimerIDs: ids)
    }
    XCTAssertThrowsError(try PrimerOrderExportService.prepare(snapshot: snapshot,
      selection: changed(ids: Array(valid.selectedPrimerIDs.dropLast()))))
    XCTAssertThrowsError(try PrimerOrderExportService.prepare(snapshot: snapshot,
      selection: changed(ids: valid.selectedPrimerIDs + [valid.selectedPrimerIDs[0]])))
    XCTAssertThrowsError(try PrimerOrderExportService.prepare(snapshot: snapshot,
      selection: changed(ids: valid.selectedPrimerIDs, settings: .init(filterByCompatibility: true))))
    XCTAssertThrowsError(try PrimerOrderExportService.prepare(snapshot: snapshot,
      selection: changed(ids: valid.selectedPrimerIDs, url: fixture.root)))
  }

  func testPublishesExactSubsetWithFinalEvidenceAndRejectsAlteredOrders() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let original = try fileBytes(fixture.bundle)
    let session = PrimerAnalysisDisplaySession()
    session.configure(snapshot); session.onOrderExportRequested = { _, _ in }
    session.setPoolShown(1, resultID: snapshot.designReview[0].sourceResultID, shown: false)
    session.setPrimerShown(snapshot.designReview[1].primers[1].id, shown: false)
    let captured = try session.makeOrderDraft()
    XCTAssertEqual(captured.oligos.count, 2)
    let destination = try PrimerAnalysisExportDestination(projectURL: fixture.root, name: "MHC order", kind: .primerOrder)
    let output = try await PrimerOrderExportService().export(selection: captured.selection,
      metadata: .init(name: "MHC order", requestedBy: "Researcher", project: "MHC", notes: "Frozen subset"),
      destinationURL: destination.url, invocationArgv: ["Lungfish", "test-order-export"])
    XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: try XCTUnwrap(AnalysesFolder.readAnalysisMetadata(from: output)).tool), .primerOrder)
    let loaded = try PrimerOrderExportService.load(from: output)
    XCTAssertEqual(loaded.oligos, captured.oligos)
    XCTAssertEqual(loaded.metadata.requestedBy, "Researcher")
    XCTAssertEqual(try fileBytes(fixture.bundle), original)
    let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
    XCTAssertEqual(provenance.exitStatus, 0)
    XCTAssertEqual(provenance.steps.count, 4)
    for descriptor in provenance.files + provenance.outputs {
      XCTAssertTrue(descriptor.path.hasPrefix(output.path + "/"), descriptor.path)
      let path = URL(fileURLWithPath: descriptor.path)
      XCTAssertEqual(try ProvenanceFileHasher.sha256(of: path), descriptor.checksumSHA256)
      XCTAssertEqual(try ProvenanceFileHasher.fileSize(of: path), descriptor.fileSize)
    }
    for step in provenance.steps {
      XCTAssertFalse((step.durableReplayArgv ?? step.argv).contains { $0.contains(".primer-order-") })
    }
    let csv = try String(contentsOf: output.appendingPathComponent("ordering.csv"), encoding: .utf8)
    XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 3)
    XCTAssertFalse(csv.contains("Scheme_1_Pool_1"))
    XCTAssertFalse(csv.contains("LEFT_1"))
    let moved = fixture.root.appendingPathComponent("renamed-order")
    try FileManager.default.moveItem(at: output, to: moved)
    XCTAssertEqual(try PrimerOrderExportService.load(from: moved).oligos, captured.oligos)
    try Data("altered".utf8).write(to: moved.appendingPathComponent("ordering.csv"))
    XCTAssertThrowsError(try PrimerOrderExportService.load(from: moved))
  }

  func testCancellationCorruptSourceAndExistingDestinationDoNotPublish() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let selection = try draft(snapshot).selection
    let destination = fixture.root.appendingPathComponent("cancelled")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await PrimerOrderExportService().export(selection: selection, metadata: .init(),
        destinationURL: destination, invocationArgv: ["test"])
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    do {
      _ = try await PrimerOrderExportService().export(selection: selection, metadata: .init(), destinationURL: destination, invocationArgv: ["test"])
      XCTFail("Expected no overwrite")
    } catch { XCTAssertTrue(error.localizedDescription.contains("already exists")) }
    try Data("corrupt".utf8).write(to: fixture.bundle.appendingPathComponent("native1/primer.bed"))
    let corrupt = fixture.root.appendingPathComponent("corrupt-order")
    do {
      _ = try await PrimerOrderExportService().export(selection: selection, metadata: .init(), destinationURL: corrupt, invocationArgv: ["test"])
      XCTFail("Expected integrity failure")
    } catch { XCTAssertTrue(error.localizedDescription.contains("integrity")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
  }

  private func draft(_ snapshot: PrimerAnalysisViewerSnapshot) throws -> PrimerOrderDraft {
    let session = PrimerAnalysisDisplaySession()
    session.configure(snapshot); session.onOrderExportRequested = { _, _ in }
    return try session.makeOrderDraft()
  }

  private func makeFixture() throws -> (root: URL, bundle: URL) {
    let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(pointer) }
    let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let inputID = UUID()
    var payloads = ["inputs/source.fasta": ">reference\nAACCGGTTAACC\n"]
    var results: [PrimerAnalysisResult] = []
    for index in 1...2 {
      let prefix = "native\(index)/"
      payloads[prefix + "reference.fasta"] = ">reference\nAACCGGTTAACC\n"
      payloads[prefix + "primer.bed"] = "reference\t2\t4\tfixture_1_LEFT_0\t1\t+\tCC\nreference\t2\t4\tfixture_1_LEFT_1\t1\t+\tCR\nreference\t8\t10\tfixture_1_RIGHT_0\t1\t-\tTT\n"
      payloads[prefix + "amplicon.bed"] = "reference\t2\t10\tfixture_1\t1\n"
      results.append(.init(id: UUID(), label: "MHC scheme \(index)", inputIDs: [inputID],
        artifactPaths: payloads.keys.filter { $0.hasPrefix(prefix) }.sorted()))
    }
    let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
      let source = root.appendingPathComponent(UUID().uuidString)
      try Data(text.utf8).write(to: source)
      return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path,
        role: path.hasPrefix("inputs/") ? "input" : "nativeOutput", format: path.hasSuffix(".bed") ? "bed" : "fasta")
    }
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
      analysisID: UUID(), runID: UUID(), grouping: .independent,
      inputs: [.init(id: inputID, artifactPaths: ["inputs/source.fasta"])], results: results, artifacts: artifacts,
      destinationURL: root.appendingPathComponent("source.lungfishprimeranalysis"),
      invocation: .init(argv: ["stored-MHC-order-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, bundle.url)
  }

  private func fileBytes(_ root: URL) throws -> [String: Data] {
    let iterator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var files: [String: Data] = [:]
    for case let url as URL in iterator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      files[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
    }
    return files
  }
}
