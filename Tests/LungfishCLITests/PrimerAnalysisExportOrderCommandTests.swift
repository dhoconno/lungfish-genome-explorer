import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class PrimerAnalysisExportOrderCommandTests: XCTestCase {
  func testRegisteredCommandParsesScopesPairsAndMetadata() throws {
    let pair = UUID().uuidString
    let command = try XCTUnwrap(LungfishCLI.parseAsRoot([
      "primers", "analysis", "export-order", "input.lungfishprimeranalysis", "--output", "/tmp/order",
      "--scope", "candidate-pairs", "--candidate-pair-id", pair, "--name", "Lab order",
      "--requested-by", "Bench", "--project", "Study", "--order-reference", "PO-1", "--notes", "Rush",
    ]) as? PrimerAnalysisExportOrderCommand)
    XCTAssertEqual(command.scope, .candidatePairs)
    XCTAssertEqual(command.candidatePairIDs, [pair])
    XCTAssertEqual(command.name, "Lab order")
    XCTAssertEqual(command.requestedBy, "Bench")
    XCTAssertEqual(command.project, "Study")
    XCTAssertEqual(command.orderReference, "PO-1")
    XCTAssertEqual(command.notes, "Rush")

    let defaults = try PrimerAnalysisExportOrderCommand.parse(["input.lungfishprimeranalysis", "--output", "/tmp/o"])
    XCTAssertNil(defaults.scope)
    XCTAssertNil(defaults.name)
    XCTAssertEqual(defaults.requestedBy, "")
    for scope in ["selected-assays", "all-reported-assays", "displayed"] {
      XCTAssertNoThrow(try PrimerAnalysisExportOrderCommand.parse(["a", "--output", "/tmp/o", "--scope", scope]))
    }
    XCTAssertThrowsError(try PrimerAnalysisExportOrderCommand.parse(["a", "--output", "/tmp/o", "--scope", "everything"]))
    XCTAssertThrowsError(try PrimerAnalysisExportOrderCommand.parse(["a", "--output", "/tmp/o",
      "--candidate-pair-id", "not-a-uuid"]))
    XCTAssertThrowsError(try PrimerAnalysisExportOrderCommand.parse(["a", "--output", "/tmp/o",
      "--scope", "selected-assays", "--candidate-pair-id", pair]))
    XCTAssertThrowsError(try PrimerAnalysisExportOrderCommand.parse(["a"]), "--output is required")

    let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand(path: ["primers", "analysis", "export-order"]))
    XCTAssertTrue(policy.requiresProvenance)
  }

  func testExportsPrimer3CandidatePairOrderThroughTheSharedService() async throws {
    let fixture = try makePrimer3Fixture(pairCount: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let second = try XCTUnwrap(snapshot.designReview.filter { $0.presentation == .primer3Template }.last).id
    let output = fixture.root.appendingPathComponent("Pair order")
    let command = try PrimerAnalysisExportOrderCommand.parse([fixture.bundle.path, "--output", output.path,
      "--candidate-pair-id", second.lowercased(), "--requested-by", "Bench"])
    try await command.run()

    let loaded = try PrimerOrderExportService.loadSnapshot(from: output)
    XCTAssertEqual(loaded.document.metadata.name, "fixture candidate pairs order")
    XCTAssertEqual(loaded.document.metadata.requestedBy, "Bench")
    XCTAssertEqual(loaded.document.selection.selectedAssayIDs, [second])
    XCTAssertEqual(Set(loaded.document.oligos.map(\.poolName)), ["Template_1_Candidate_2"])
    XCTAssertEqual(loaded.provenance.workflowName, "Export Primer3 candidate pairs")
    let files = Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
    XCTAssertTrue(files.isSuperset(of: ["order.json", "ordering.csv", "primer-order.xlsx", "template.xlsx"]))
    XCTAssertFalse(files.contains("IDT-oPools.xlsx"), "Alternative pairs have no pools to upload")

    // The GUI draft for the same pair captures the identical oligos.
    let gui = try PrimerOrderExportService.captureSelection(snapshot: snapshot,
      scope: .primer3CandidatePairs(includedPairIDs: [second]))
    XCTAssertEqual(try PrimerOrderExportService.prepare(snapshot: snapshot, selection: gui), loaded.document.oligos)

    // An existing destination is never replaced.
    let again = try PrimerAnalysisExportOrderCommand.parse([fixture.bundle.path, "--output", output.path])
    do { try await again.run(); XCTFail("An existing order directory must be refused") } catch {}
  }

  func testWrongScopeForAnalysisKindFailsWithoutWritingOutput() async throws {
    let fixture = try makePrimer3Fixture(pairCount: 1)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let output = fixture.root.appendingPathComponent("order")
    let command = try PrimerAnalysisExportOrderCommand.parse([fixture.bundle.path, "--output", output.path,
      "--scope", "selected-assays"])
    do {
      try await command.run()
      XCTFail("selected-assays must be refused for a Primer3 analysis")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Olivar or varVAMP"), error.localizedDescription)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    let missingParent = try PrimerAnalysisExportOrderCommand.parse([fixture.bundle.path, "--output",
      fixture.root.appendingPathComponent("absent/order").path])
    do { try await missingParent.run(); XCTFail("A missing parent must be refused") } catch {}
  }

  /// `--scope displayed` is accepted by the parser for every engine, but only
  /// PrimalScheme has display filters, so a Primer3 analysis must be refused with a
  /// message naming the scope it does offer, and the help must say so up front.
  func testDisplayedScopeIsRefusedForEnginesWithoutDisplayFilters() async throws {
    let fixture = try makePrimer3Fixture(pairCount: 1)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let output = fixture.root.appendingPathComponent("displayed-order")
    let command = try PrimerAnalysisExportOrderCommand.parse([fixture.bundle.path, "--output", output.path,
      "--scope", "displayed"])
    do {
      try await command.run()
      XCTFail("displayed must be refused for a Primer3 analysis")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("PrimalScheme"), error.localizedDescription)
      XCTAssertTrue(error.localizedDescription.contains("Primer3 candidate pairs"), error.localizedDescription)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

    let help = PrimerAnalysisExportOrderCommand.helpMessage()
    XCTAssertTrue(help.contains("displayed (PrimalScheme only)"), help)
    XCTAssertTrue(help.contains("refused"), help)
  }

  private func makePrimer3Fixture(pairCount: Int) throws -> (root: URL, bundle: URL) {
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
    let pairs: [[String: Any]] = (0..<pairCount).map { index in
      ["id": UUID().uuidString, "productSize": 8 - index,
       "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
       "right": oligo(start: 6 - index, end: 8 - index, orientation: "reverse", sequence: index == 0 ? "AC" : "GT")]
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
    let physicalBundle = try XCTUnwrap(realpath(bundle.url.path, nil))
    defer { free(physicalBundle) }
    return (root, URL(fileURLWithPath: String(cString: physicalBundle)))
  }
}
