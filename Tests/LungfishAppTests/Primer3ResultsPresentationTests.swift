import AppKit
import SwiftUI
import Darwin
import Foundation
import XCTest
import LungfishIO
import LungfishWorkflow
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
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let results = try XCTUnwrap(snapshot.primer3Results)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let primer = try XCTUnwrap(target.primers.first)
    let selection = PrimerReviewSelection.selecting(primer: primer, in: target)
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for width in [CGFloat(1000), CGFloat(650)] {
      let host = NSHostingView(rootView: ScrollView {
        Primer3ResultsView(results: results, bundleURL: fixture.bundle,
          reviewTargets: snapshot.designReview, selection: .constant(selection)).padding(24)
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
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
      try png.write(to: output.appendingPathComponent("primer3-normalized-results\(suffix).png"))
      window.close()
    }

  }

  private func makeFixture(rightEnd: Int = 8, wrongMembership: Bool = false, omitNormalizedResult: Bool = false) throws -> (root: URL, bundle: URL) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("input.fasta")
    try Data(">synthetic-display-fixture\nACGTACGT\n".utf8).write(to: input)
    let native = root.appendingPathComponent("native.txt")
    try Data("Synthetic display fixture, not an engine execution.\n".utf8).write(to: native)
    let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
    func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
      ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
       "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
    }
    var document: [String: Any] = [
      "schemaVersion": 1, "analysisID": analysisID.uuidString, "runID": runID.uuidString,
      "results": [[
        "resultID": resultID.uuidString, "inputID": (wrongMembership ? UUID() : inputID).uuidString,
        "title": "Synthetic display fixture", "sourceKind": "fasta", "sourceIndex": 0,
        "sourceRecordID": "synthetic-display-fixture",
        "templateSequence": "ACGTACGT", "excludedRegions": [],
        "pairs": [["id": UUID().uuidString, "productSize": rightEnd,
          "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
          "right": oligo(start: 6, end: rightEnd, orientation: "reverse", sequence: "AC")]],
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
