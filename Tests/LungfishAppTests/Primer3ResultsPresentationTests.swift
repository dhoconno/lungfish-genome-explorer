import AppKit
import SwiftUI
import Darwin
import Foundation
import XCTest
import LungfishIO
import LungfishWorkflow
import ViewInspector
@testable import LungfishApp

final class Primer3ResultsPresentationTests: XCTestCase {
  func testValidNormalizedResultsLoadWithStableMembership() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let results = try XCTUnwrap(snapshot.primer3Results)
    XCTAssertEqual(results.results.count, 1)
    XCTAssertEqual(results.results[0].pairs[0].right.start, 6)
    XCTAssertEqual(snapshot.groupingLabel, "Independent primer design per selected template")
  }

  func testPrimer3SectionsExcludeBindingEvenWithUnrelatedInspectionContexts() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    XCTAssertEqual(snapshot.availableSections, [.overview, .results])
    XCTAssertEqual(snapshot.visibleSection(.binding), .overview)
    XCTAssertEqual(snapshot.visibleSection(.results), .results)
    snapshot.bindingContexts = [.init(id: "unrelated", title: "Unrelated alignment", alignedFASTA: ">row\nACGT\n",
      annotations: [], primers: [.init(id: "primer", name: "Primer", sequence: "AC", strand: "+",
        alignedStart: 0, alignedEnd: 2, contiguousReference: true)], unavailableReason: nil,
      rows: [.init(name: "row", sequence: Array("ACGT"))])]
    XCTAssertEqual(snapshot.availableSections, [.overview, .results])
    XCTAssertFalse(snapshot.supportsBindingInspection)
  }

  @MainActor
  func testStaleBindingSelectionShowsPrimer3OverviewAndTemplateMap() async throws {
    let fixture = try makeFixture(includeProbe: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = PrimerAnalysisViewerModel()
    await model.load(from: fixture.bundle)
    let view = PrimerAnalysisViewerView(bundleURL: fixture.bundle, model: model, selectedSection: .binding)
    let inspected = try view.inspect()
    XCTAssertThrowsError(try inspected.find(text: "Binding inspection"))
    XCTAssertNoThrow(try inspected.find(ViewType.View<Primer3TemplateReviewCard>.self))
    XCTAssertNoThrow(try inspected.find(text: "Saved design template"))
  }

  @MainActor
  func testPrimer3TemplateMapLabelsPositionsAndSelectsExactPrimerAndProduct() throws {
    let fixture = try makeFixture(includeProbe: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    var selection: PrimerReviewSelection?
    let view = PrimerTargetReviewCard(target: target,
      selection: Binding(get: { selection }, set: { selection = $0 }))
    let inspected = try view.inspect()
    XCTAssertNoThrow(try inspected.find(ViewType.View<Primer3TemplateReviewCard>.self))
    XCTAssertNoThrow(try inspected.find(text: "Product · 8 bp"))
    XCTAssertNoThrow(try inspected.find(text: "Forward primer →"))
    XCTAssertNoThrow(try inspected.find(text: "Reverse primer ←"))
    XCTAssertNoThrow(try inspected.find(text: "Internal probe →"))
    for coordinates in ["1–2", "7–8", "4–5"] {
      XCTAssertNoThrow(try inspected.find(text: coordinates))
    }
    let reverse = try XCTUnwrap(target.primers.first { $0.strand == "-" })
    try inspected.find(ViewType.Button.self, where: {
      try $0.accessibilityIdentifier() == "primerReview.primer.\(reverse.id)"
    }).tap()
    XCTAssertEqual(selection, .selecting(primer: reverse, in: target))
    XCTAssertEqual(reverse.sequence, "AC", "Synthesis sequence must not be reverse-complemented for the map")
    let interval = try XCTUnwrap(target.intervals.first)
    try inspected.find(ViewType.Button.self, where: {
      try $0.accessibilityIdentifier() == "primerReview.amplicon.\(interval.id)"
    }).tap()
    XCTAssertEqual(selection, .init(targetID: target.id, primerID: nil, ampliconID: interval.id))
  }

  @MainActor
  func testPrimer3EmptyOutputShowsExplanationWithoutProductMap() throws {
    let fixture = try makeFixture(noPairs: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let inspected = try PrimerTargetReviewCard(target: target).inspect()
    XCTAssertNoThrow(try inspected.find(ViewType.View<Primer3TemplateReviewCard>.self))
    XCTAssertNoThrow(try inspected.find(text: "No candidate pairs"))
    XCTAssertNoThrow(try inspected.find(text: "No pairs met the fixture constraints."))
    XCTAssertTrue(inspected.findAll(ViewType.Button.self).isEmpty)
    XCTAssertThrowsError(try inspected.find(text: "0.0%"))
  }

  func testOutOfBoundsCoordinatesDoNotRenderAsValidResults() throws {
    let fixture = try makeFixture(rightEnd: 100)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle))
  }

  func testWrongResultMembershipDoesNotRender() throws {
    let fixture = try makeFixture(wrongMembership: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle))
  }

  func testMissingNormalizedResultDoesNotSilentlyHideMembership() throws {
    let fixture = try makeFixture(omitNormalizedResult: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle))
  }

  @MainActor
  func testRenderNormalizedResults() async throws {
    guard let outputPath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
    }
    let fixture = try makeFixture(includeProbe: true, visualCandidates: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let primer = try XCTUnwrap(target.primers.first)
    let selection = PrimerReviewSelection.selecting(primer: primer, in: target)
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for section in snapshot.availableSections {
    for width in [CGFloat(1000), CGFloat(650)] {
      let model = PrimerAnalysisViewerModel()
      await model.load(from: fixture.bundle)
      let host = NSHostingView(rootView: PrimerAnalysisViewerView(bundleURL: fixture.bundle, model: model,
        selectedSection: section, selection: section == .results ? selection : nil))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.appearance = NSAppearance(named: .aqua)
      host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let suffix = width == 650 ? "-narrow" : ""
      let name = section == .results ? "primer3-normalized-results" : "primer3-overview"
      try png.write(to: output.appendingPathComponent("\(name)\(suffix).png"))
      window.close()
    }
    }

  }

  private func makeFixture(rightEnd: Int = 8, wrongMembership: Bool = false, omitNormalizedResult: Bool = false,
                           includeProbe: Bool = false, noPairs: Bool = false,
                           visualCandidates: Bool = false) throws -> (root: URL, bundle: URL) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("input.fasta")
    let template = String(repeating: "ACGT", count: visualCandidates ? 300 : 2)
    try Data(">synthetic-display-fixture\n\(template)\n".utf8).write(to: input)
    let native = root.appendingPathComponent("native.txt")
    try Data("Synthetic display fixture, not an engine execution.\n".utf8).write(to: native)
    let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
    func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
      ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
       "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
    }
    var pair: [String: Any] = ["id": UUID().uuidString, "productSize": visualCandidates ? 220 : rightEnd,
      "left": oligo(start: visualCandidates ? 40 : 0, end: visualCandidates ? 60 : 2,
        orientation: "forward", sequence: visualCandidates ? String(repeating: "ACGT", count: 5) : "AC"),
      "right": oligo(start: visualCandidates ? 240 : 6, end: visualCandidates ? 260 : rightEnd,
        orientation: "reverse", sequence: visualCandidates ? String(repeating: "ACGT", count: 5) : "AC")]
    if includeProbe {
      pair["internalOligo"] = oligo(start: visualCandidates ? 125 : 3, end: visualCandidates ? 145 : 5,
        orientation: "forward", sequence: visualCandidates ? String(repeating: "CGTA", count: 5) : "TA")
    }
    var pairs = [pair]
    if visualCandidates {
      pairs.append(["id": UUID().uuidString, "productSize": 250,
        "left": oligo(start: 100, end: 120, orientation: "forward", sequence: String(repeating: "ACGT", count: 5)),
        "right": oligo(start: 330, end: 350, orientation: "reverse", sequence: String(repeating: "GTAC", count: 5))])
    }
    var document: [String: Any] = [
      "schemaVersion": 1, "analysisID": analysisID.uuidString, "runID": runID.uuidString,
      "results": [[
        "resultID": resultID.uuidString, "inputID": (wrongMembership ? UUID() : inputID).uuidString,
        "title": "Synthetic display fixture", "sourceKind": "fasta", "sourceIndex": 0,
        "sourceRecordID": "synthetic-display-fixture",
        "templateSequence": template, "excludedRegions": [],
        "pairs": noPairs ? [] : pairs,
        "explanation": noPairs ? "No pairs met the fixture constraints." : "Synthetic candidate fixture.",
      ]],
    ]
    if omitNormalizedResult { document["results"] = [] as [Any] }
    let normalized = root.appendingPathComponent("normalized.json")
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
    let path = "results/primer3-normalized-v1.json"
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
      analysisID: analysisID, runID: runID, grouping: .independent,
      inputs: [.init(id: inputID, label: "Fixture", artifactPaths: ["inputs/input.fasta"])],
      results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
      artifacts: [
        .init(sourceURL: input, relativePath: "inputs/input.fasta", role: "input", format: "fasta"),
        .init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"),
        .init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"),
      ], destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, bundle.url)
  }
}
