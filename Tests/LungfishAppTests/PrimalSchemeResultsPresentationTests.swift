import AppKit
import SwiftUI
import XCTest
import ViewInspector
@testable import LungfishApp

final class PrimalSchemeResultsPresentationTests: XCTestCase {
  @MainActor
  func testSelectedAmpliconShowsAllSixReverseVariantsWithoutRankingPairs() throws {
    let (result, target) = try selectedVariantFixture()
    let interval = try XCTUnwrap(target.intervals.first)
    var selection: PrimerReviewSelection? = .init(targetID: target.id, primerID: nil, ampliconID: interval.id)
    let binding = Binding(get: { selection }, set: { selection = $0 })
    let detail = try PrimerAmpliconDetailView(target: target, selection: binding).inspect()
    XCTAssertNoThrow(try detail.find(text: "Selected primer set"))
    XCTAssertNoThrow(try detail.find(text: "Forward variants (LEFT) · 1"))
    XCTAssertNoThrow(try detail.find(text: "Reverse variants (RIGHT) · 6"))
    for primer in result.primers {
      XCTAssertNoThrow(try detail.find(text: primer.name))
    }
    XCTAssertEqual(interval.primerIDs.count, 7)
    let last = try XCTUnwrap(target.primers.last)
    try detail.find(ViewType.Button.self, where: {
      (try? $0.find(text: last.name)) != nil
    }).tap()
    XCTAssertEqual(selection?.primerID, last.id)
    XCTAssertEqual(selection?.ampliconID, interval.id)
    let results = try PrimalSchemeResultsView(results: [result], reviewTargets: [target], selection: binding).inspect()
    XCTAssertNoThrow(try results.find(text: "Selected scheme oligos"))
  }

  private func selectedVariantFixture() throws -> (PrimalSchemeDisplayResult, PrimerTargetDesignReview) {
    let reference = Data((">reference\n" + String(repeating: "ACGT", count: 100) + "\n").utf8)
    let variants = ["ACGTACGTACGTACGTACGT", "CCGTACGTACGTACGTACGT", "GCGTACGTACGTACGTACGT",
                    "TCGTACGTACGTACGTACGT", "AGGTACGTACGTACGTACGT", "ATGTACGTACGTACGTACGT"]
    let lines = ["reference\t10\t30\tfixture_1_LEFT_1\t2\t+\tACGTACGTACGTACGTACGT"] + variants.enumerated().map {
      "reference\t190\t210\tfixture_1_RIGHT_\($0.offset + 1)\t2\t-\t\($0.element)"
    }
    let result = try PrimalSchemeDisplayResult.parse(id: "native/selected/primer.bed", title: "Selected variant fixture",
      bed: Data((lines.joined(separator: "\n") + "\n").utf8), reference: reference)
    let target = try XCTUnwrap(PrimerDesignReview.primalScheme(id: result.id, label: result.title, reference: reference,
      amplicons: Data("reference\t10\t210\tfixture_1\t2\n".utf8), primers: result.primers, labels: [:]).first)
    return (result, target)
  }

  @MainActor
  func testRenderSelectedVariantSets() async throws {
    guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
    }
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var targets: [(String, PrimerTargetDesignReview)] = [("synthetic", try selectedVariantFixture().1)]
    if let bundlePath = ProcessInfo.processInfo.environment["LUNGFISH_SELECTED_SCHEME_BUNDLE"] {
      let snapshot = try PrimerAnalysisViewerSnapshot.load(from: URL(fileURLWithPath: bundlePath))
      let target = try XCTUnwrap(snapshot.designReview.first { target in
        target.intervals.contains { $0.primerIDs.count > 2 }
      })
      targets.append(("native-mhc", target))
    }
    for (name, target) in targets {
      let interval = try XCTUnwrap(target.intervals.first { $0.primerIDs.count > 2 })
      let selection = PrimerReviewSelection(targetID: target.id, primerID: nil, ampliconID: interval.id)
      for width in [CGFloat(650), CGFloat(1000)] {
        let host = NSHostingView(rootView: ScrollView {
          PrimerTargetReviewCard(target: target, selection: .constant(selection)).padding(20)
        }.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("selected-set-\(name)-\(Int(width)).png"))
        window.close()
      }
    }
  }

  func testNativePoolColumnAndCoordinatesPreserveAlternativeRecords() throws {
    let result = try fixture()
    XCTAssertEqual(result.primers.count, 2)
    XCTAssertEqual(result.primers[0].pool, 2)
    XCTAssertEqual(result.primers[1].pool, 1)
    XCTAssertEqual(result.primers[1].start, 6)
    XCTAssertEqual(result.primers[1].referenceLabel, "HLA:A*01:01")
    XCTAssertEqual(result.primers[1].sequence, "AC")
  }

  func testPoolReviewDoesNotInventGCForAmbiguousOligos() throws {
    let result = try PrimalSchemeDisplayResult.parse(id: "test", title: "Test",
      bed: Data("reference\t0\t2\tambiguous\t1\t+\tAN\nreference\t2\t4\texact\t1\t-\tGC\n".utf8),
      reference: Data(">reference\nACGT\n".utf8))
    XCTAssertEqual(result.primers[0].ambiguousBaseCount, 1)
    XCTAssertEqual(result.primers[0].gcLabel, "GC varies")
    XCTAssertEqual(result.primers[1].gcLabel, "100.0% GC")
    XCTAssertNil(result.orderSheetURL)
  }

  func testMappedIndelsPreserveBindingSpanSeparatelyFromOligoLength() throws {
    let result = try PrimalSchemeDisplayResult.parse(id: "test", title: "Test",
      bed: Data("reference\t0\t3\tP\t1\t+\tAC\n".utf8),
      reference: Data(">reference\nACGT\n".utf8))
    XCTAssertEqual(result.primers[0].end - result.primers[0].start, 3)
    XCTAssertEqual(result.primers[0].sequence.count, 2)
  }

  func testMissingReferenceAndOutOfBoundsCoordinatesRejectMisleadingDisplay() {
    let fasta = Data(">reference\nACGTACGT\n".utf8)
    for bed in ["missing\t0\t2\tprimer\t1\t+\tAC", "reference\t7\t9\tprimer\t1\t+\tAC",
                "reference\t0\t2\tprimer\t0\t+\tAC", "reference\t0\t2\tprimer\t1\t+\t!!"] {
      XCTAssertThrowsError(try PrimalSchemeDisplayResult.parse(id: "test", title: "Test", bed: Data(bed.utf8), reference: fasta))
    }
  }

  @MainActor
  func testRenderStoredScheme() async throws {
    guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
      throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
    }
    let result = try fixture()
    let host = NSHostingView(rootView: PrimalSchemeResultsView(results: [result]).padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    window.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let output = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try png.write(to: output.appendingPathComponent("primalscheme-native-results.png"))
  }

  private func fixture() throws -> PrimalSchemeDisplayResult {
    try PrimalSchemeDisplayResult.parse(id: "native/fixture/primer.bed", title: "Synthetic display fixture",
      bed: Data("# artic-bed-version v3.0\nreference\t0\t2\tfixture_LEFT\t2\t+\tAC\nreference\t6\t8\tfixture_RIGHT_alt1\t1\t-\tAC\n".utf8),
      reference: Data(">reference\nACGTACGT\n".utf8), referenceLabels: ["reference": "HLA:A*01:01"])
  }
}
