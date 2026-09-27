import Darwin
import Foundation
import LungfishIO
import LungfishWorkflow
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp

/// Primer3 candidate pairs can be ordered, and pairs designed from an alignment can be
/// inspected against every saved row. Single-sequence templates explain themselves instead.
@MainActor
final class Primer3OrderAndBindingTests: XCTestCase {
  func testAlignmentTemplateBuildsBindingContextsForEveryCandidateOligo() throws {
    let fixture = try makeFixture(msa: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    XCTAssertEqual(snapshot.availableSections, [.overview, .results, .binding])
    XCTAssertTrue(snapshot.supportsBindingInspection)
    XCTAssertNil(snapshot.bindingUnavailableExplanation)
    let context = try XCTUnwrap(snapshot.inspectableBindingContexts.first)
    XCTAssertEqual(context.title, "Template row")
    XCTAssertEqual(context.rows.map(\.name), ["Template row", "Second row", "Gapped row"])
    XCTAssertEqual(context.primers.count, 2)
    // Template column 0..<2 maps to alignment columns 1..<3 because the template row starts with a gap.
    let forward = try XCTUnwrap(context.primers.first { $0.name.contains("Forward") })
    XCTAssertEqual(forward.alignedStart, 1)
    XCTAssertEqual(forward.alignedEnd, 3)
    XCTAssertTrue(forward.contiguousReference)
    let review = try XCTUnwrap(snapshot.designReview.first)
    XCTAssertEqual(Set(context.primers.map(\.reviewPrimerID)), Set(review.primers.map(\.id)))
    let comparisons = try context.comparisons(for: forward)
    XCTAssertEqual(comparisons.map(\.status), [
      "0 mismatches (IUPAC-compatible)", "1 positional mismatches", "Unavailable: internal alignment gap",
    ])
    let summaries = try PrimerMSACompatibilitySummary.compute(contexts: [context])
    XCTAssertEqual(summaries[forward.reviewPrimerID]?.matchingRows, 1)
    XCTAssertEqual(summaries[forward.reviewPrimerID]?.assessableRows, 2)
  }

  func testInspectorViewTabListsCandidatePairsAndExportsIncludedPairsAsOrderGroups() async throws {
    let fixture = try makeFixture(msa: false, pairCount: 2, includeProbe: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let session = PrimerAnalysisDisplaySession()
    session.configure(snapshot)
    XCTAssertTrue(session.isAvailable)
    XCTAssertTrue(session.hasPrimer3Candidates)
    XCTAssertFalse(session.hasSchemeDisplayControls)
    XCTAssertEqual(session.primer3Candidates.count, 2)
    XCTAssertEqual(session.orderExportUnavailableReason, "Open this analysis in its project to export an order.")
    XCTAssertTrue(session.schemeExportUnavailableReason?.contains("Primer3") == true)

    let model = InspectorViewModel()
    model.primerAnalysisDocument = .init(bundleURL: fixture.bundle)
    model.primerAnalysisDisplaySession = session
    XCTAssertTrue(model.availableTabs.contains(.view))
    model.selectedTab = .view
    let inspected = try InspectorView(viewModel: model).inspect()
    XCTAssertNoThrow(try inspected.find(text: "Primer3 candidates"))
    XCTAssertNoThrow(try inspected.find(text: "2 of 2 candidate pairs included"))
    XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: "primerAnalysisDisplay.saveScheme"))

    session.onOrderExportRequested = { _, _ in }
    let excluded = session.primer3Candidates[1]
    session.setPrimer3CandidateIncluded(excluded.id, included: false)
    XCTAssertEqual(session.includedPrimer3Candidates.count, 1)
    let draft = try session.makeOrderDraft()
    XCTAssertTrue(draft.selection.isPrimer3CandidateSelection)
    XCTAssertEqual(draft.selection.selectedAssayIDs, [session.primer3Candidates[0].id])
    XCTAssertEqual(draft.oligos.count, 3)
    XCTAssertEqual(draft.oligos.map(\.oligoRole), [.forward, .probe, .reverse])
    XCTAssertEqual(Set(draft.oligos.map(\.poolName)), ["Template_1_Candidate_1"])
    // Names come from the record ID and keep whole fields. "synthetic-display-fixture"
    // is one character over the limit, so the last whole field is dropped rather than
    // cut: the old behaviour produced "Synthetic_display_fixtur", stopping mid-field.
    XCTAssertEqual(draft.oligos.map(\.name), ["synthetic-display_P1_LEFT",
      "synthetic-display_P1_PROBE", "synthetic-display_P1_RIGHT"])
    XCTAssertTrue(draft.oligos.allSatisfy { $0.pool == nil && $0.nativePool == nil && $0.sourceOligoID != nil })
    XCTAssertTrue(draft.defaultName.hasSuffix(" candidate pairs order"))

    session.setPrimer3CandidateIncluded(session.primer3Candidates[0].id, included: false)
    XCTAssertEqual(session.orderExportUnavailableReason, "Include at least one candidate pair to export an order.")
    XCTAssertThrowsError(try session.makeOrderDraft())

    let destination = try PrimerAnalysisExportDestination(projectURL: fixture.root, name: "Pair order", kind: .primerOrder)
    let output = try await PrimerOrderExportService().export(selection: draft.selection,
      metadata: .init(name: "Pair order"), destinationURL: destination.url, invocationArgv: ["Lungfish", "test-primer3-order"])
    let loaded = try PrimerOrderExportService.loadSnapshot(from: output)
    XCTAssertEqual(loaded.document.oligos, draft.oligos)
    XCTAssertTrue(loaded.document.sequenceSemantics.contains("independent alternative"))
    XCTAssertEqual(loaded.provenance.workflowName, "Export Primer3 candidate pairs")
    let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
    XCTAssertTrue(files.contains("primer-order.xlsx"))
    XCTAssertTrue(files.contains("ordering.csv"))
    XCTAssertFalse(files.contains("IDT-oPools.xlsx"), "Alternative pairs have no pools to upload")
    let csv = try String(contentsOf: output.appendingPathComponent("ordering.csv"), encoding: .utf8)
    XCTAssertTrue(csv.contains("Template_1_Candidate_1"))
    XCTAssertFalse(csv.contains("Candidate_2"))
    // A stale selection whose pairs no longer match is refused.
    var stale = draft.selection
    stale = PrimerOrderSelection(capturedAt: stale.capturedAt, analysisURL: stale.analysisURL, manifest: stale.manifest,
      settings: stale.settings, compatibilityReady: false, compatibilitySummaries: [:],
      selectedPrimerIDs: Array(stale.selectedPrimerIDs.dropLast()), selectedAssayIDs: stale.selectedAssayIDs,
      primer3CandidatePairs: true)
    XCTAssertThrowsError(try PrimerOrderExportService.prepare(snapshot: snapshot, selection: stale))
  }

  func testContextMenuOffersAlignmentInspectionForPrimer3CandidatesWithContexts() throws {
    let fixture = try makeFixture(msa: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let primer = try XCTUnwrap(target.primers.first)
    let contexts = snapshot.inspectableBindingContexts
    let bindingIDs = PrimerAnalysisVisibility().bindingPrimerIDs(in: contexts, targets: snapshot.designReview)
    XCTAssertTrue(bindingIDs.contains(primer.id))
    // The item used to be hidden for Primer3 targets. It now appears and follows the binding set.
    let menu = try PrimerReviewContextMenu(target: target, item: .primer(primer), selection: .constant(nil)).inspect()
    XCTAssertNoThrow(try menu.find(button: "Inspect in Alignment"))
    let interval = try XCTUnwrap(target.intervals.first)
    let ampliconMenu = try PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: .constant(nil)).inspect()
    XCTAssertNoThrow(try ampliconMenu.find(button: "Inspect Amplicon"))
  }

  // MARK: Fixture

  private func makeFixture(msa: Bool, pairCount: Int = 1, includeProbe: Bool = false) throws -> (root: URL, bundle: URL) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
    // Template row "-ACGTACGT" holds template ACGTACGT at alignment columns 1..<9.
    let template = "ACGTACGT"
    let aligned = [("Template row", "-ACGTACGT"), ("Second row", "-AGGTACGT"), ("Gapped row", "-A-GTACGT")]
    var artifacts: [PrimerAnalysisSourceArtifact] = []
    var inputPaths: [String] = []
    let input = root.appendingPathComponent("input.fasta")
    try Data(">\(inputID.uuidString)\n\(template)\n".utf8).write(to: input)
    artifacts.append(.init(sourceURL: input, relativePath: "inputs/\(inputID.uuidString).fasta", role: "input", format: "fasta"))
    inputPaths.append("inputs/\(inputID.uuidString).fasta")
    if msa {
      let alignedFASTA = root.appendingPathComponent("primary.aligned.fasta")
      try Data(aligned.map { ">\($0.0)\n\($0.1)\n" }.joined().utf8).write(to: alignedFASTA)
      let rows: [[String: Any]] = aligned.enumerated().map { index, row in
        ["id": "row-\(index)", "sourceName": row.0, "displayName": row.0, "order": index, "alphabet": "dna",
         "alignedLength": row.1.count, "ungappedLength": row.1.filter { $0 != "-" }.count,
         "gapCount": row.1.filter { $0 == "-" }.count, "ambiguousCount": 0, "checksumSHA256": "", "metadata": [:]]
      }
      let rowsJSON = root.appendingPathComponent("rows.json")
      try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: rowsJSON)
      let prefix = "source-inputs/\(inputID.uuidString)/source.lungfishmsa/"
      artifacts.append(.init(sourceURL: alignedFASTA, relativePath: prefix + "alignment/primary.aligned.fasta", role: "input", format: "fasta"))
      artifacts.append(.init(sourceURL: rowsJSON, relativePath: prefix + "metadata/rows.json", role: "input", format: "json"))
      inputPaths += [prefix + "alignment/primary.aligned.fasta", prefix + "metadata/rows.json"]
    }
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
      if includeProbe {
        pair["internalOligo"] = oligo(start: 3, end: 5, orientation: "forward", sequence: "TA")
      }
      pairs.append(pair)
    }
    var result: [String: Any] = [
      "resultID": resultID.uuidString, "inputID": inputID.uuidString,
      "title": msa ? "Template row" : "Synthetic display fixture", "sourceKind": msa ? "msa" : "fasta",
      "sourceIndex": 0, "sourceRecordID": msa ? "row-0" : "synthetic-display-fixture",
      "templateSequence": template, "excludedRegions": [], "pairs": pairs, "explanation": "Synthetic candidate fixture.",
    ]
    if msa { result["alignmentToTemplate"] = [NSNull(), 0, 1, 2, 3, 4, 5, 6, 7] }
    let document: [String: Any] = ["schemaVersion": 1, "analysisID": analysisID.uuidString,
      "runID": runID.uuidString, "results": [result]]
    let normalized = root.appendingPathComponent("normalized.json")
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
    let path = "results/primer3-normalized-v1.json"
    artifacts.append(.init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"))
    artifacts.append(.init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"))
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
      analysisID: analysisID, runID: runID, grouping: .independent,
      inputs: [.init(id: inputID, label: "Fixture", artifactPaths: inputPaths)],
      results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
      artifacts: artifacts, destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, bundle.url)
  }
}
