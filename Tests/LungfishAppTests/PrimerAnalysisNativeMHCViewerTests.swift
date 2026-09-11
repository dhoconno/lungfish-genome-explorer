import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

/// Manual fixture verification of actual engine outputs; no fixtures are downloaded by this test.
@MainActor
final class PrimerAnalysisNativeMHCViewerTests: XCTestCase {
  func testLoadAndRenderNativeMHCAnalyses() async throws {
    guard let rootPath = ProcessInfo.processInfo.environment["LUNGFISH_MHC_PRIMER_VALIDATION_DIR"] else {
      throw XCTSkip("Set LUNGFISH_MHC_PRIMER_VALIDATION_DIR to inspect retained human/macaque CLI outputs")
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let urls = try Self.analysisURLs(in: root)
    XCTAssertFalse(urls.isEmpty, "No native analysis bundles found")
    var rendered: Set<String> = []
    for url in urls.sorted(by: { $0.path < $1.path }) {
      let snapshot = try PrimerAnalysisViewerSnapshot.load(from: url)
      let engine = snapshot.primer3Results == nil ? "primalscheme3" : "primer3"
      if engine == "primalscheme3" { XCTAssertFalse(snapshot.primalSchemeResults.isEmpty, url.path) }
      guard let outputPath = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"],
        rendered.insert(engine).inserted else { continue }
      let model = PrimerAnalysisViewerModel()
      await model.load(from: url)
      let host = NSHostingView(rootView: PrimerAnalysisViewerView(bundleURL: url, model: model, selectedSection: .results))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = host
      window.appearance = NSAppearance(named: .aqua)
      host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(300))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let output = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try png.write(to: output.appendingPathComponent("native-mhc-\(engine)-results.png"))
    }
  }

  private static func analysisURLs(in root: URL) throws -> [URL] {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "lungfishprimeranalysis" {
      urls.append(url)
      enumerator.skipDescendants()
    }
    return urls
  }

}
