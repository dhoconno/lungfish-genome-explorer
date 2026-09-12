import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

final class PrimalSchemeResultsPresentationTests: XCTestCase {
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
