import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// The GUI and CLI capture order selections through one shared function.
final class PrimerOrderCaptureSelectionTests: XCTestCase {
  func testPrimer3DefaultScopeIncludesEveryCandidatePairInSavedOrder() throws {
    let fixture = try makePrimer3Fixture(pairCount: 2, includeProbe: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let candidates = snapshot.designReview.filter { $0.presentation == .primer3Template }
    let scope = PrimerOrderExportService.defaultScope(for: snapshot)
    XCTAssertEqual(scope, .primer3CandidatePairs(includedPairIDs: candidates.map(\.id)))
    XCTAssertEqual(PrimerOrderExportService.defaultOrderName(analysisURL: fixture.bundle, scope: scope),
      "fixture candidate pairs order")

    let selection = try PrimerOrderExportService.captureSelection(snapshot: snapshot, scope: scope)
    XCTAssertTrue(selection.isPrimer3CandidateSelection)
    XCTAssertNil(selection.includesAllReportedAssays)
    XCTAssertEqual(selection.selectedAssayIDs, candidates.map(\.id))
    XCTAssertEqual(selection.selectedPrimerIDs.count, 6)
    let oligos = try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection)
    XCTAssertEqual(oligos.map(\.oligoRole), [.forward, .probe, .reverse, .forward, .probe, .reverse])
    // Order groups are named after the record and pair, like the oligos.
    XCTAssertEqual(oligos.map(\.poolName), oligos.map { oligo in
      String(oligo.name[..<oligo.name.lastIndex(of: "_")!])
    })
    XCTAssertEqual(Set(oligos.map(\.poolName)).count, 2)
    XCTAssertTrue(oligos.allSatisfy { $0.poolName.hasSuffix("_P1") || $0.poolName.hasSuffix("_P2") })
    XCTAssertFalse(oligos.contains { $0.poolName.contains("Template_") })
  }

  func testPrimer3SubsetKeepsSavedOrderAcceptsLowercaseAndRejectsUnknownPairs() throws {
    let fixture = try makePrimer3Fixture(pairCount: 2, includeProbe: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let candidates = snapshot.designReview.filter { $0.presentation == .primer3Template }
    let second = candidates[1].id
    let selection = try PrimerOrderExportService.captureSelection(snapshot: snapshot,
      scope: .primer3CandidatePairs(includedPairIDs: [second.lowercased()]))
    XCTAssertEqual(selection.selectedAssayIDs, [second])
    let oligos = try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection)
    XCTAssertEqual(Set(oligos.map(\.poolName)).count, 1)
    XCTAssertTrue(oligos.allSatisfy { $0.poolName.hasSuffix("_P2") && $0.name.hasPrefix($0.poolName + "_") })

    XCTAssertThrowsError(try PrimerOrderExportService.captureSelection(snapshot: snapshot,
      scope: .primer3CandidatePairs(includedPairIDs: [UUID().uuidString])))
    XCTAssertThrowsError(try PrimerOrderExportService.captureSelection(snapshot: snapshot,
      scope: .primer3CandidatePairs(includedPairIDs: ["not-a-uuid"])))
    XCTAssertThrowsError(try PrimerOrderExportService.captureSelection(snapshot: snapshot,
      scope: .primer3CandidatePairs(includedPairIDs: [second, second])))
    XCTAssertThrowsError(try PrimerOrderExportService.captureSelection(snapshot: snapshot,
      scope: .primer3CandidatePairs(includedPairIDs: [])))
  }

  func testScopesThatDoNotMatchTheAnalysisKindAreRefused() throws {
    let fixture = try makePrimer3Fixture(pairCount: 1, includeProbe: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    for scope in [PrimerOrderScope.selectedAssays, .allReportedAssays, .displayed] {
      XCTAssertThrowsError(try PrimerOrderExportService.captureSelection(snapshot: snapshot, scope: scope)) { error in
        XCTAssertTrue(error.localizedDescription.contains("Primer3 candidate pairs"), error.localizedDescription)
      }
    }
  }

  /// A synthetic saved Primer3 analysis on one FASTA template, written by the real bundle writer.
  func makePrimer3Fixture(pairCount: Int, includeProbe: Bool) throws -> (root: URL, bundle: URL) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
    let template = "ACGTACGT"
    let input = root.appendingPathComponent("input.fasta")
    try Data(">\(inputID.uuidString)\n\(template)\n".utf8).write(to: input)
    let native = root.appendingPathComponent("native.txt")
    try Data("Synthetic Primer3 fixture, not an engine execution.\n".utf8).write(to: native)
    func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
      ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
       "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
    }
    var pairs: [[String: Any]] = []
    for index in 0..<pairCount {
      var pair: [String: Any] = ["id": UUID().uuidString, "productSize": 8 - index,
        "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
        "right": oligo(start: 6 - index, end: 8 - index, orientation: "reverse", sequence: index == 0 ? "AC" : "GT")]
      if includeProbe { pair["internalOligo"] = oligo(start: 3, end: 5, orientation: "forward", sequence: "TA") }
      pairs.append(pair)
    }
    let result: [String: Any] = [
      "resultID": resultID.uuidString, "inputID": inputID.uuidString,
      "title": "Synthetic display fixture", "sourceKind": "fasta",
      "sourceIndex": 0, "sourceRecordID": "synthetic-display-fixture",
      "templateSequence": template, "excludedRegions": [], "pairs": pairs, "explanation": "Synthetic candidate fixture.",
    ]
    let document: [String: Any] = ["schemaVersion": 1, "analysisID": analysisID.uuidString,
      "runID": runID.uuidString, "results": [result]]
    let normalized = root.appendingPathComponent("normalized.json")
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
    let path = "results/primer3-normalized-v1.json"
    let artifacts: [PrimerAnalysisSourceArtifact] = [
      .init(sourceURL: input, relativePath: "inputs/\(inputID.uuidString).fasta", role: "input", format: "fasta"),
      .init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"),
      .init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"),
    ]
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
      analysisID: analysisID, runID: runID, grouping: .independent,
      inputs: [.init(id: inputID, label: "Fixture", artifactPaths: ["inputs/\(inputID.uuidString).fasta"])],
      results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
      artifacts: artifacts, destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, bundle.url)
  }
}
